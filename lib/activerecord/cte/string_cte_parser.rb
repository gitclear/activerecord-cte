# frozen_string_literal: true

module Activerecord
  # ---------------------------------------------------------------------------
  module Cte
    # ---------------------------------------------------------------------------
    # WORKAROUND: String CTE Parsing
    #
    # This module exists to handle a limitation in how Arel processes CTE (Common Table Expression) strings.
    # When a string is passed to the `with()` method, Arel expects an `Arel::Nodes::As` node structure,
    # but raw strings are converted to `Arel::Nodes::SqlLiteral` which doesn't have the table name
    # information that Arel's CTE visitor (`collect_ctes`) requires.
    #
    # The CTE visitor calls `quote_table_name` on what it expects to be a table name, but gets `nil`
    # from SqlLiteral nodes, causing the "no implicit conversion of nil into String" error.
    #
    # This workaround manually parses the string to extract:
    # 1. The table name (with support for quoted identifiers)
    # 2. The SQL expression
    # And constructs a proper `Arel::Nodes::As` node that Arel can process correctly.
    #
    # WHEN CAN THIS BE REMOVED?
    # This workaround can be removed when:
    # 1. Arel's CTE visitor is updated to handle SqlLiteral nodes properly, OR
    # 2. ActiveRecord provides built-in string CTE parsing, OR
    # 3. We decide to remove support for String CTE definitions (breaking change)
    #
    # CURRENT STATUS (Rails 6.1.7.9 + Ruby 3.2):
    # - Rails 6.0: String CTEs worked (through undocumented Arel behavior)
    # - Rails 6.1: String CTE support BROKE - this is where our current issue originates
    # - Rails 7.1 (October 2023): Added basic .with() CTE support but ONLY for Hash/Arel nodes
    #   - PR #37944: https://github.com/rails/rails/pull/37944 (merged July 2022)
    #   - Does NOT include string CTE support - strings still cause the same SqlLiteral issue
    # - Rails 7.2 (August 2024): Added .with_recursive() support but still no string support
    #   - Only supports: Post.with_recursive(name: [base_query, recursive_query])
    #   - Strings still converted to SqlLiteral causing nil table name issues
    #
    # RAILS CORE TEAM DECISION:
    # - PR #42563 (June 2021): Attempted to fix string CTE support in Rails 6.1+
    #   - https://github.com/rails/rails/pull/42563
    #   - Was CLOSED/REJECTED in November 2021 (marked as stale)
    #   - Rails core team chose NOT to restore string CTE functionality
    #   - This suggests string CTEs are considered unsupported/deprecated behavior
    #
    # UPGRADE PATH:
    # Rails 6.0 → 6.1+: String CTEs BROKE and will NOT be fixed by Rails core team
    # Rails 6.1.7.9 → 7.1: This workaround STILL NEEDED for string CTEs
    # Rails 7.1 → 7.2: This workaround STILL NEEDED for string CTEs
    # Rails 7.3+: String CTE support unlikely to be added (based on rejected PR #42563)
    #
    # REFERENCES:
    # - Rails 7.1 CTE docs: https://guides.rubyonrails.org/active_record_querying.html#common-table-expressions
    # - Original Rails CTE PR: https://github.com/rails/rails/pull/37944
    # - Rejected string CTE fix PR: https://github.com/rails/rails/pull/42563
    # - Rails 7.2 recursive support: https://edgeguides.rubyonrails.org/7_2_release_notes.html
    #
    # Until Rails officially supports string CTEs, this ensures string CTEs work as users
    # expect while maintaining compatibility with the existing Arel infrastructure.
    module StringCteParser
      # CTE String Parsing Constants
      # These constants break down the complex regex for better readability and debugging

      # Matches table names enclosed in backticks: `table_name`
      # Examples that MATCH:
      #   `users` → captures "users"
      #   `user_posts` → captures "user_posts"
      #   `complex table name` → captures "complex table name"
      # Examples that DON'T match:
      #   users (no backticks)
      #   `users (missing closing backtick)
      BACKTICK_QUOTED_TABLE = /`([^`]+)`/.freeze

      # Matches table names enclosed in double quotes: "table_name"
      # Examples that MATCH:
      #   "users" → captures "users"
      #   "user_posts" → captures "user_posts"
      #   "complex table name" → captures "complex table name"
      # Examples that DON'T match:
      #   users (no quotes)
      #   "users (missing closing quote)
      DOUBLE_QUOTED_TABLE = /"([^"]+)"/.freeze

      # Matches unquoted table names: must start with letter/underscore, can contain letters/numbers/underscores
      # Examples that MATCH:
      #   users → captures "users"
      #   user_posts → captures "user_posts"
      #   _private_table → captures "_private_table"
      #   table123 → captures "table123"
      #   User_Posts_2023 → captures "User_Posts_2023"
      # Examples that DON'T match:
      #   123users (starts with number)
      #   user-posts (contains hyphen)
      #   user.posts (contains dot)
      #   "users" (has quotes - handled by other patterns)
      UNQUOTED_TABLE = /([a-zA-Z_][a-zA-Z0-9_]*)/.freeze

      # Combines all table name patterns with non-capturing group
      # Examples that MATCH:
      #   `users` → captures "users" from backtick group
      #   "user_posts" → captures "user_posts" from quote group
      #   popular_posts → captures "popular_posts" from unquoted group
      # Note: Only one capture group will have a value, the others will be nil
      TABLE_NAME_PATTERN = /(?:#{BACKTICK_QUOTED_TABLE}|#{DOUBLE_QUOTED_TABLE}|#{UNQUOTED_TABLE})/.freeze

      # Matches the AS keyword (case insensitive)
      # Examples that MATCH:
      #   AS, as, As, aS (any case combination)
      # Examples that DON'T match:
      #   A S (space in between)
      #   ASS (too many letters)
      AS_KEYWORD = /AS/i.freeze

      # Matches the SQL expression inside parentheses (greedy match for everything inside)
      # Examples that MATCH:
      #   (SELECT * FROM posts) → captures "SELECT * FROM posts"
      #   (SELECT id, name FROM users WHERE active = true) → captures "SELECT id, name FROM users WHERE active = true"
      #   (SELECT * FROM posts WHERE views > (SELECT AVG(views) FROM posts)) → captures "SELECT * FROM posts WHERE views > (SELECT AVG(views) FROM posts)"
      # Examples that DON'T match:
      #   SELECT * FROM posts (no parentheses)
      #   (SELECT * FROM posts (missing closing paren)
      #   SELECT * FROM posts) (missing opening paren)
      EXPRESSION_PATTERN = /\((.+)\)/.freeze

      # Complete CTE string pattern: optional whitespace + table_name + whitespace + AS + whitespace + (expression) + optional whitespace
      # Examples that MATCH:
      #   "popular_posts AS (SELECT * FROM posts WHERE views_count > 100)"
      #   "  `user stats`   AS   (SELECT COUNT(*) FROM users)  "
      #   '"complex_table" as (SELECT * FROM posts)'
      #   "table_2023 AS (SELECT id FROM posts WHERE created_at > '2023-01-01')"
      # Examples that DON'T match:
      #   "popular_posts (SELECT * FROM posts)" (missing AS)
      #   "popular_posts AS SELECT * FROM posts" (missing parentheses)
      #   "AS (SELECT * FROM posts)" (missing table name)
      #   "123_table AS (SELECT * FROM posts)" (invalid table name)
      CTE_STRING_PATTERN = /\A\s*#{TABLE_NAME_PATTERN}\s+#{AS_KEYWORD}\s+#{EXPRESSION_PATTERN}\s*\z/i.freeze

      # ---------------------------------------------------------------------------
      # Main parsing method that converts a CTE string into an Arel::Nodes::As node
      # that Arel's CTE visitor can process correctly
      def self.parse(string)
        # Match against our comprehensive CTE pattern
        match = string.match(CTE_STRING_PATTERN)

        unless match
          # Provide more specific error messages for common mistakes
          if string.strip.empty?
            raise ArgumentError, "CTE string cannot be empty"
          elsif !string.match(/\sAS\s/i)
            raise ArgumentError,
                  "CTE string must contain 'AS' keyword. Expected 'table_name AS (SELECT ...)' but got: #{string}"
          elsif !string.include?("(") || !string.include?(")")
            raise ArgumentError,
                  "CTE expression must be enclosed in parentheses. Expected 'table_name AS (SELECT ...)' but got: #{string}"
          else
            raise ArgumentError, "Invalid CTE string format. Expected 'table_name AS (SELECT ...)' but got: #{string}"
          end
        end

        # Extract table name from whichever group matched (backtick, double-quote, or unquoted)
        # Regexp.last_match(1) = backtick group, (2) = double-quote group, (3) = unquoted group
        # The expression is always in the last group (4)
        table_name = Regexp.last_match(1) || Regexp.last_match(2) || Regexp.last_match(3)
        expression = Regexp.last_match(4)

        # Validation: Ensure we extracted meaningful values
        validate_cte_components(table_name, expression)

        # Validate SQL structure
        validate_expression_syntax(expression)

        # Build the proper Arel structure that the CTE visitor expects
        table = Arel::Table.new(table_name.to_sym)
        Arel::Nodes::As.new(table, Arel::Nodes::SqlLiteral.new("(#{expression})"))
      end

      # ---------------------------------------------------------------------------
      # Validates that the extracted CTE components are not empty or whitespace-only
      def self.validate_cte_components(table_name, expression)
        raise ArgumentError, "Empty table name in CTE string" if table_name.nil? || table_name.strip.empty?

        raise ArgumentError, "Empty expression in CTE string" if expression.nil? || expression.strip.empty?
      end

      # ---------------------------------------------------------------------------
      # Validates basic SQL syntax - primarily checking for balanced parentheses
      # This catches common copy-paste errors and malformed SQL
      def self.validate_expression_syntax(expression)
        # Check for balanced parentheses to catch malformed SQL early
        paren_count = 0
        expression.each_char do |char|
          case char
          when "("
            paren_count += 1
          when ")"
            paren_count -= 1
            # If we have more closing than opening parens, fail immediately
            break if paren_count.negative?
          end
        end

        raise ArgumentError, "Unbalanced parentheses in CTE expression: #{expression}" unless paren_count.zero?
      end
    end
  end
end
