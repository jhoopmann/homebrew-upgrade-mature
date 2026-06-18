# frozen_string_literal: true
require 'abstract_command'
require "cask"
require "formula"
require 'utils/github'
require 'time'
require 'sorbet-runtime'

module Homebrew
  class UpgradeMature < AbstractCommand
    extend T::Sig

    BREW_UPGRADE_MATURE_THRESHOLD = (ENV["HOMEBREW_UPGRADE_MATURE_THRESHOLD"] || "7").to_f
    ENV["PATH"] = PATH.new(ORIGINAL_PATHS).to_s

    cmd_args do
      description <<~EOS
        Upgrades packages whose commits are older than the threshold defined in $BREW_UPGRADE_MATURE_THRESHOLD (in days).
      EOS

      switch "--dry-run", "-n",
        description: "Show what would be upgraded, but do not actually upgrade anything."

      switch "--no-ask", "--yes", "-y",
        description: "Do not ask for confirmation before downloading and upgrading. Ask mode is the default."

      switch "-f", "--force",
        description: "Install formulae without checking for previously installed keg-only or " \
                     "non-migrated versions. When installing casks, overwrite existing files " \
                     "(binaries and symlinks are excluded, unless originally from the same cask)."

      switch "--cask", "--casks", 
        description: "Treat all named arguments as casks. If no named arguments " \
                      "are specified, upgrade only outdated casks."

      switch "--formula", "--formulae",
        description: "Treat all named arguments as formulae. If no named arguments " \
                      "are specified, upgrade only outdated formulae."

      switch "--skip-cask-deps",
        description: "Skip installing cask dependencies."

      switch "--greedy",
        description: "Also include casks with `version :latest` and `auto_updates true` casks " \
                     "that would otherwise be skipped.",
        env: :upgrade_greedy

      switch "--greedy-latest",
        description: "Also include casks with `version :latest`."

      switch "--greedy-auto-updates",
        description: "Also include `auto_updates true` casks that would otherwise be skipped."

      switch "--[no-]binaries",
        description: "Disable/enable linking of helper executables (default: enabled).",
        env: :cask_opts_binaries

      switch "--require-sha",
        description: "Require all casks to have a checksum.",
        env: :cask_opts_require_sha

      conflicts "--cask", "--formula"
      conflicts "--formula", "--greedy", "--greedy-latest", "--greedy-auto-updates", "--[no-]binaries", "--require-sha", "--skip-cask-deps"

      named_args [:formula, :cask], min: 0
    end

    sig { void }
    def run
      outdated_formulas = get_outdated_formulas

      if outdated_formulas.empty?
        puts Formatter.headline("No outdated formulas found!", color: :green)
        abort
      end

      puts Formatter.headline("Found #{outdated_formulas.count} outdated formulas!")

      evaluated_formulas = evaluate_formulas(outdated_formulas)

      denied_evaluated_formulas = filter_evaluated_formulas(evaluated_formulas, false)
      puts_evaluated_formulas("Denied:", :red, denied_evaluated_formulas)

      allowed_evaluated_formulas = filter_evaluated_formulas(evaluated_formulas, true)
      puts_evaluated_formulas("Allowed: ", :green, allowed_evaluated_formulas)

      unless args.dry_run? || allowed_evaluated_formulas.empty?
        wait_for_confirmation("Confirm installation of allowed packages?") unless args.no_ask?
        install_evaluated_formulas(allowed_evaluated_formulas)
      end
    end

    private

    EvaluatedFormula = Struct.new(:formula_name, :version, :committed_date, :allowed)

    sig { returns(T::Array[T.untyped]) }
    def get_outdated_formulas
      casks =
        (Cask::Caskroom.casks.select do |c|
          c.outdated?(
            greedy: args.greedy?,
            greedy_latest: args.greedy_latest?,
            greedy_auto_updates: args.greedy_auto_updates?
          )
        end.to_a unless args.formula?) || []

      formulas = (Formula.installed.select(&:outdated?).to_a unless args.cask?) || []

      (casks + formulas).filter do |f|
        args.named.empty? || args.named.include?(f.is_a?(Formula) ? f.name : f.token)
      end
    end

    sig { params(formulas: T::Array[T.untyped]).returns(T::Array[EvaluatedFormula]) }
    def evaluate_formulas(formulas)
      commits = fetch_commits(formulas)
      max_time = Time.now - get_configured_duration

      formulas.map do |f|
        commit = filter_commit(f, commits)
        evaluate_formula(f, max_time, commit)
      end
    end

    sig { params(formula: T.untyped, max_time: Time, commit: T.nilable(T::Hash[String, T.untyped])).returns(EvaluatedFormula) }
    def evaluate_formula(formula, max_time, commit)
      allowed = false
      committed_date = nil

      if commit
        committed_date = parse_committed_date_str(commit.dig("committedDate"))
        allowed = committed_date && committed_date < max_time
      end

      EvaluatedFormula.new(formula_name: get_formula_name(formula), version: formula.version, committed_date: committed_date, allowed: allowed)
    end

    sig { params(formula: T.untyped, commits: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
    def filter_commit(formula, commits)
      formula_key = escape_formula_name(get_formula_name(formula))
      repository_key = escape_repository_name(formula.tap.full_repository)

      formula_commits =
        commits.dig(repository_key, "defaultBranchRef", "target", formula_key, "nodes") || []

      formula_commits.first unless formula_commits.empty?
    end
    
    sig { params(formulas: T::Array[T.untyped]).returns(T.untyped) }
    def fetch_commits(formulas)
      query =
        group_by_formula_repository(formulas).map do |_repo, fs|
          prepare_repository_query(fs)
        end.join("\n")

      GitHub::API.open_graphql("query { #{query} }")
    end

    sig { params(formulas: T::Array[T.untyped]).returns(T::Hash[String, T::Array[T.untyped]]) }
    def group_by_formula_repository(formulas)
      formulas.reduce({}) do |g, f|
        g[f.tap.full_repository] ||= []
        g[f.tap.full_repository] << f
        g
      end
    end

    sig { params(formula: T.untyped).returns(String) }
    def prepare_history_query(formula)
      history_key = escape_formula_name(get_formula_name(formula))

      "#{history_key}: history(first: 1, path: \"#{formula.ruby_source_path}\") {
        nodes {
          oid
          committedDate
          file(path: \"#{formula.ruby_source_path}\") {
            name
          }
        }
      }"
    end

    sig { params(formulas: T::Array[T.untyped]).returns(String) }
    def prepare_repository_query(formulas)
      user = formulas[0].tap.user
      repository_name = formulas[0].tap.full_repository
      repository_key = escape_repository_name(repository_name)

      histories = formulas.map { |f| prepare_history_query(f) }.join("\n")

      "#{repository_key}: repository(owner: \"#{user}\", name: \"#{repository_name}\") {
        defaultBranchRef {
          target {
            ... on Commit {
              #{histories}
            }
          }
        }
      }"
    end

    sig { params(evaluated_formulas: T::Array[EvaluatedFormula]).void }
    def install_evaluated_formulas(evaluated_formulas)
      names = evaluated_formulas.map { |o| o.formula_name }

      extras = []
      extras << "--no-ask"
      extras << "--force" if args.force?
      extras << "--greedy" if args.greedy?
      extras << "--greedy-latest" if args.greedy_latest?
      extras << "--greedy-auto-updates" if args.greedy_auto_updates?
      extras << "--skip-cask-deps" if args.skip_cask_deps?
      extras << "--require-sha" if args.require_sha?
      extras << "--no-binaries" unless args.binaries?

      system "brew", "upgrade", *extras, *names
    end

    sig { params(str: String).void }
    def wait_for_confirmation(str)
      puts
      print "#{str} (y/n): "

      abort unless STDIN.gets&.strip&.downcase&.start_with?("y")
    end

    sig { params(
      headline: String,
      color: Symbol,
      array: T::Array[EvaluatedFormula]
    ).void }
    def puts_evaluated_formulas(headline, color, array)
      puts
      puts Formatter.headline(headline, color: color)

      if array.empty?
        puts "(none)"
      else
        array.each { |o| puts_evaluated_formula(o) }
      end
    end

    sig { params(evaluated_formula: EvaluatedFormula).void }
    def puts_evaluated_formula(evaluated_formula) 
      puts "#{evaluated_formula.formula_name} => #{evaluated_formula.version} (#{evaluated_formula.committed_date || "no commits found"})"
    end

    sig { params(
      evaluated_formulas: T::Array[EvaluatedFormula],
      allowed: T::Boolean
    ).returns(T::Array[EvaluatedFormula]) }
    def filter_evaluated_formulas(evaluated_formulas, allowed)
      evaluated_formulas
        .filter { |o| o.allowed == allowed }
        .sort_by { |o| o.committed_date || Time.at(0) }
    end

    sig { params(committed_date_str: T.nilable(String)).returns(T.nilable(Time)) }
    def parse_committed_date_str(committed_date_str)
      Time.parse(committed_date_str) if committed_date_str
    end

    sig { params(formula: T.untyped).returns(String) }
    def get_formula_name(formula)
      formula.is_a?(Formula) ? formula.name : formula.token
    end

    sig { params(name: String).returns(String) }
    def escape_formula_name(name)
      name.gsub(/(\-|\.|\@)/, "")
    end

    sig { params(name: String).returns(String) }
    def escape_repository_name(name)
      name.gsub(/(\-|\/)/, "")
    end

    sig { returns(Float) }
    def get_configured_duration
      60 * 60 * 24 * BREW_UPGRADE_MATURE_THRESHOLD
    end
  end
end
