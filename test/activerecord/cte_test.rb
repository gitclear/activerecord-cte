# frozen_string_literal: true

require "test_helper"

require "models/post"

class Activerecord::CteTest < ActiveSupport::TestCase
  fixtures :posts

  def test_with_when_hash_is_passed_as_an_argument
    popular_posts = Post.where("views_count > 100")
    popular_posts_from_cte = Post.with(popular_posts: popular_posts).from("popular_posts AS posts")
    assert popular_posts.any?
    assert_equal popular_posts.to_a, popular_posts_from_cte
  end

  def test_with_when_string_is_passed_as_an_argument
    popular_posts = Post.where("views_count > 100")
    popular_posts_from_cte = Post.with("popular_posts AS (SELECT * FROM posts WHERE views_count > 100)").from("popular_posts AS posts")
    assert popular_posts.any?
    assert_equal popular_posts.to_a, popular_posts_from_cte
  end

  def test_with_when_arel_as_node_is_passed_as_an_argument
    popular_posts = Post.where("views_count > 100")

    posts_table = Arel::Table.new(:posts)
    cte_table = Arel::Table.new(:popular_posts)
    cte_select = posts_table.project(Arel.star).where(posts_table[:views_count].gt(100))
    as = Arel::Nodes::As.new(cte_table, cte_select)

    popular_posts_from_cte = Post.with(as).from("popular_posts AS posts")

    assert popular_posts.any?
    assert_equal popular_posts.to_a, popular_posts_from_cte
  end

  def test_with_when_array_of_arel_node_as_is_passed_as_an_argument
    popular_archived_posts = Post.where("views_count > 100").where(archived: true)

    posts_table = Arel::Table.new(:posts)
    first_cte_table = Arel::Table.new(:popular_posts)
    first_cte_select = posts_table.project(Arel.star).where(posts_table[:views_count].gt(100))
    first_as = Arel::Nodes::As.new(first_cte_table, first_cte_select)
    second_cte_table = Arel::Table.new(:popular_archived_posts)
    second_cte_select = first_cte_table.project(Arel.star).where(first_cte_table[:archived].eq(true))
    second_as = Arel::Nodes::As.new(second_cte_table, second_cte_select)

    popular_archived_posts_from_cte = Post.with([first_as, second_as]).from("popular_archived_posts AS posts")

    assert popular_archived_posts.any?
    assert_equal popular_archived_posts.to_a, popular_archived_posts_from_cte
  end

  def test_with_when_hash_with_multiple_elements_of_different_type_is_passed_as_an_argument
    popular_archived_posts_written_in_german = Post.where("views_count > 100").where(archived: true, language: :de)
    posts_table = Arel::Table.new(:posts)
    cte_options = {
      popular_posts: posts_table.project(Arel.star).where(posts_table[:views_count].gt(100)),
      popular_posts_written_in_german: "SELECT * FROM popular_posts WHERE language = 'de'",
      popular_archived_posts_written_in_german: Post.where(archived: true).from("popular_posts_written_in_german AS posts")
    }
    popular_archived_posts_written_in_german_from_cte = Post.with(cte_options).from("popular_archived_posts_written_in_german AS posts")
    assert popular_archived_posts_written_in_german_from_cte.any?
    assert_equal popular_archived_posts_written_in_german.to_a, popular_archived_posts_written_in_german_from_cte
  end

  def test_multiple_with_calls
    popular_archived_posts = Post.where("views_count > 100").where(archived: true)
    popular_archived_posts_from_cte = Post
      .with(archived_posts: Post.where(archived: true))
      .with(popular_archived_posts: "SELECT * FROM archived_posts WHERE views_count > 100")
      .from("popular_archived_posts AS posts")
    assert popular_archived_posts_from_cte.any?
    assert_equal popular_archived_posts.to_a, popular_archived_posts_from_cte
  end

  def test_multiple_with_calls_randomly_callled
    popular_archived_posts = Post.where("views_count > 100").where(archived: true)
    popular_archived_posts_from_cte = Post
      .with(archived_posts: Post.where(archived: true))
      .from("popular_archived_posts AS posts")
      .with(popular_archived_posts: "SELECT * FROM archived_posts WHERE views_count > 100")
    assert popular_archived_posts.any?
    assert_equal popular_archived_posts.to_a, popular_archived_posts_from_cte
  end

  def test_recursive_with_call
    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))

    recursive_rel = Post.with(:recursive, popular_posts: anchor_term.union(recursive_term)).from("popular_posts AS posts")
    assert_equal Post.select(:id).where("views_count > 100").to_a, recursive_rel
  end

  def test_recursive_with_call_union_all
    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))

    recursive_rel = Post.with(:recursive, popular_posts: anchor_term.union(:all, recursive_term)).from("popular_posts AS posts")
    assert_includes recursive_rel.to_sql, "UNION ALL"
  end

  def test_recursive_is_preserved_on_multiple_with_calls
    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id], posts[:archived]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id], posts[:archived]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))

    recursive_rel = Post.with(:recursive, popular_posts: anchor_term.union(recursive_term)).from("popular_posts AS posts")

    assert_equal Post.select(:id).where("views_count > 100").to_a, recursive_rel
    assert_equal Post.select(:id).where("views_count > 100").where(archived: true).to_a, recursive_rel.where(archived: true)
  end

  def test_multiple_with_calls_with_recursive_and_non_recursive_queries
    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))

    archived_popular_posts = Post
      .with(archived_posts: Post.where(archived: true))
      .with(:recursive, popular_posts: anchor_term.union(recursive_term))
      .from("popular_posts AS posts")
      .joins("INNER JOIN archived_posts ON archived_posts.id = posts.id")

    assert archived_popular_posts.to_sql.start_with?("WITH RECURSIVE ")
    assert_equal posts(:two, :three).pluck(:id).sort, archived_popular_posts.to_a.pluck(:id).sort
  end

  def test_recursive_with_query_called_as_non_recursive
    # Recursive queries works in SQLite without RECURSIVE
    return if ActiveRecord::Base.connection.adapter_name == "SQLite"

    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))

    non_recursive_rel = Post.with(popular_posts: anchor_term.union(recursive_term)).from("popular_posts AS posts")
    assert_raise ActiveRecord::StatementInvalid do
      non_recursive_rel.load
    end
  end

  def test_count_after_with_call
    posts_count = Post.all.count
    popular_posts_count = Post.where("views_count > 100").count
    assert posts_count > popular_posts_count
    assert popular_posts_count.positive?

    with_relation = Post.with(popular_posts: Post.where("views_count > 100"))
    assert_equal posts_count, with_relation.count
    assert_equal popular_posts_count, with_relation.from("popular_posts AS posts").count
    assert_equal popular_posts_count, with_relation.joins("JOIN popular_posts ON popular_posts.id = posts.id").count
  end

  def test_with_when_called_from_active_record_scope
    popular_posts = Post.where("views_count > 100")
    assert_equal popular_posts.to_a, Post.popular_posts
  end

  def test_with_when_invalid_params_are_passed
    assert_raise(ArgumentError) { Post.with.load }
    assert_raise(ArgumentError) { Post.with([{ popular_posts: Post.where("views_count > 100") }]).load }
    assert_raise(ArgumentError) { Post.with(popular_posts: nil).load }
    assert_raise(ArgumentError) { Post.with(popular_posts: [Post.where("views_count > 100")]).load }
  end

  def test_with_when_merging_relations
    most_popular = Post.with(most_popular: Post.where("views_count >= 100").select("id as post_id")).joins("join most_popular on most_popular.post_id = posts.id")
    least_popular = Post.with(least_popular: Post.where("views_count <= 400").select("id as post_id")).joins("join least_popular on least_popular.post_id = posts.id")
    merged = most_popular.merge(least_popular)

    assert_equal(1, merged.size)
    assert_equal(123, merged[0].views_count)
  end

  def test_with_when_merging_relations_with_identical_with_names_and_identical_queries
    most_popular1 = Post.with(most_popular: Post.where("views_count >= 100"))
    most_popular2 = Post.with(most_popular: Post.where("views_count >= 100"))

    merged = most_popular1.merge(most_popular2).from("most_popular as posts")

    assert_equal posts(:two, :three, :four).sort, merged.sort
  end

  def test_with_when_merging_relations_with_a_mixture_of_strings_and_relations
    most_popular1 = Post.with(most_popular: Post.where(views_count: 456))
    most_popular2 = Post.with(most_popular: Post.where("views_count = 456"))

    merged = most_popular1.merge(most_popular2)

    assert_raise ActiveRecord::StatementInvalid do
      merged.load
    end
  end

  def test_with_when_merging_relations_with_identical_with_names_and_different_queries
    most_popular1 = Post.with(most_popular: Post.where("views_count >= 100"))
    most_popular2 = Post.with(most_popular: Post.where("views_count <= 100"))

    merged = most_popular1.merge(most_popular2)

    assert_raise ActiveRecord::StatementInvalid do
      merged.load
    end
  end

  def test_with_when_merging_relations_with_recursive_and_non_recursive_queries
    non_recursive_rel = Post.with(archived_posts: Post.where(archived: true))

    posts = Arel::Table.new(:posts)
    popular_posts = Arel::Table.new(:popular_posts)
    anchor_term = posts.project(posts[:id]).where(posts[:views_count].gt(100))
    recursive_term = posts.project(posts[:id]).join(popular_posts).on(posts[:id].eq(popular_posts[:id]))
    recursive_rel = Post.with(:recursive, popular_posts: anchor_term.union(recursive_term))

    merged_rel = non_recursive_rel
      .merge(recursive_rel)
      .from("popular_posts AS posts")
      .joins("INNER JOIN archived_posts ON archived_posts.id = posts.id")

    assert merged_rel.to_sql.start_with?("WITH RECURSIVE ")
    assert_equal posts(:two, :three).pluck(:id).sort, merged_rel.to_a.pluck(:id).sort
  end

  def test_update_all_works_as_expected
    Post.with(most_popular: Post.where("views_count >= 100")).update_all(views_count: 123)
    assert_equal [123], Post.pluck(Arel.sql("DISTINCT views_count"))
  end

  def test_delete_all_works_as_expected
    Post.with(most_popular: Post.where("views_count >= 100")).delete_all
    assert_equal 0, Post.count
  end

  def test_string_cte_with_quoted_table_names
    # Test with backticks
    popular_posts = Post.where("views_count > 100")
    popular_posts_from_cte = Post.with("`popular_posts` AS (SELECT * FROM posts WHERE views_count > 100)").from("popular_posts AS posts")
    assert popular_posts.any?
    assert_equal popular_posts.to_a, popular_posts_from_cte

    # Test with double quotes
    popular_posts_from_cte2 = Post.with('"popular_posts" AS (SELECT * FROM posts WHERE views_count > 100)').from("popular_posts AS posts")
    assert_equal popular_posts.to_a, popular_posts_from_cte2
  end

  def test_string_cte_with_complex_sql_and_nested_parentheses
    # Test with nested parentheses and complex SQL
    complex_cte = "complex_posts AS (SELECT * FROM posts WHERE views_count > (SELECT AVG(views_count) FROM posts) AND language IN ('en', 'de'))"
    posts_from_complex_cte = Post.with(complex_cte).from("complex_posts AS posts")

    # Should execute without errors
    assert_nothing_raised { posts_from_complex_cte.load }
  end

  def test_string_cte_case_insensitive_as_keyword
    # Test case variations of AS keyword
    popular_posts = Post.where("views_count > 100")

    # lowercase 'as'
    popular_posts_from_cte1 = Post.with("popular_posts as (SELECT * FROM posts WHERE views_count > 100)").from("popular_posts AS posts")
    assert_equal popular_posts.to_a, popular_posts_from_cte1

    # mixed case 'As'
    popular_posts_from_cte2 = Post.with("popular_posts As (SELECT * FROM posts WHERE views_count > 100)").from("popular_posts AS posts")
    assert_equal popular_posts.to_a, popular_posts_from_cte2

    # uppercase 'AS'
    popular_posts_from_cte3 = Post.with("popular_posts AS (SELECT * FROM posts WHERE views_count > 100)").from("popular_posts AS posts")
    assert_equal popular_posts.to_a, popular_posts_from_cte3
  end

  def test_string_cte_with_whitespace_variations
    popular_posts = Post.where("views_count > 100")

    # Extra whitespace
    cte_with_spaces = "   popular_posts   AS   (   SELECT * FROM posts WHERE views_count > 100   )   "
    popular_posts_from_cte = Post.with(cte_with_spaces).from("popular_posts AS posts")
    assert_equal popular_posts.to_a, popular_posts_from_cte
  end

  def test_string_cte_error_handling
    # Test invalid formats
    assert_raise(ArgumentError, "Should reject CTE without AS keyword") do
      Post.with("popular_posts (SELECT * FROM posts)").load
    end

    assert_raise(ArgumentError, "Should reject CTE without parentheses") do
      Post.with("popular_posts AS SELECT * FROM posts").load
    end

    assert_raise(ArgumentError, "Should reject CTE with unbalanced parentheses") do
      Post.with("popular_posts AS (SELECT * FROM posts WHERE views_count > (100").load
    end

    assert_raise(ArgumentError, "Should reject CTE with unbalanced parentheses") do
      Post.with("popular_posts AS (SELECT * FROM posts WHERE views_count > 100))").load
    end

    assert_raise(ArgumentError, "Should reject CTE with empty table name") do
      Post.with(" AS (SELECT * FROM posts)").load
    end

    assert_raise(ArgumentError, "Should reject CTE with empty expression") do
      Post.with("popular_posts AS ()").load
    end

    assert_raise(ArgumentError, "Should reject CTE with whitespace-only expression") do
      Post.with("popular_posts AS (   )").load
    end
  end

  def test_string_cte_with_underscores_and_numbers
    # Test table names with underscores and numbers
    cte_string = "popular_posts_2023 AS (SELECT * FROM posts WHERE views_count > 100)"
    popular_posts_from_cte = Post.with(cte_string).from("popular_posts_2023 AS posts")

    popular_posts = Post.where("views_count > 100")
    assert_equal popular_posts.to_a, popular_posts_from_cte
  end

  def test_string_cte_with_multiline_expressions
    # Test multiline CTE expressions with complex formatting
    multiline_cte = <<~SQL.strip
      filtered_tracker_issue_extras AS (
        SELECT tie.scheduled_in_external_sprint_ids,
              tie.tracker_project_issue_id
        FROM tracker_issue_extras tie
        JOIN repo_issues ri
          ON ri.tracker_project_issue_id = tie.tracker_project_issue_id
        WHERE ri.primary_committer_id = ANY(ARRAY[1]::bigint[])
          AND ri.repo_id               = ANY(ARRAY[2, 3, 1]::bigint[])
      )
    SQL

    # This should parse successfully without raising an error
    assert_nothing_raised do
      Post.with(multiline_cte).to_sql
    end

    # Test with newlines in different positions
    cte_with_newlines = "popular_posts AS (\n  SELECT *\n  FROM posts\n  WHERE views_count > 100\n)"
    assert_nothing_raised do
      Post.with(cte_with_newlines).to_sql
    end

    # Test with complex nested subqueries and multiline formatting
    complex_multiline_cte = <<~SQL.strip
      complex_analysis AS (
        SELECT
          p.id,
          p.title,
          (SELECT COUNT(*)
           FROM comments c
           WHERE c.post_id = p.id
             AND c.created_at > '2023-01-01') as recent_comments,
          CASE
            WHEN p.views_count > 1000 THEN 'popular'
            WHEN p.views_count > 100 THEN 'moderate'
            ELSE 'low'
          END as popularity
        FROM posts p
        WHERE p.published_at IS NOT NULL
      )
    SQL

    assert_nothing_raised do
      Post.with(complex_multiline_cte).to_sql
    end
  end

  def test_string_cte_with_user_provided_multiline_example
    # Test the specific multiline example provided by the user
    user_multiline_cte = "filtered_tracker_issue_extras AS (\n  SELECT tie.scheduled_in_external_sprint_ids,\n        tie.tracker_project_issue_id\n  FROM tracker_issue_extras tie\n  JOIN repo_issues ri\n    ON ri.tracker_project_issue_id = tie.tracker_project_issue_id\n  WHERE ri.primary_committer_id = ANY(ARRAY[[1]]::bigint[])\n    AND ri.repo_id               = ANY(ARRAY[[2, 3, 1]]::bigint[])\n)\n"

    # This should parse successfully without raising an error
    result = Post.with(user_multiline_cte).to_sql

    # The table name gets quoted by PostgreSQL, so check for quoted version
    assert result.include?("WITH \"filtered_tracker_issue_extras\" AS"), "Should include WITH clause with user's table name (quoted)"
    assert result.include?("tie.scheduled_in_external_sprint_ids"), "Should include specific column from user's example"
    assert result.include?("tracker_issue_extras tie"), "Should include table alias from user's example"
    assert result.include?("JOIN repo_issues ri"), "Should include JOIN clause from user's example"
    assert result.include?("ARRAY[[1]]::bigint[]"), "Should preserve complex array syntax"
    assert result.include?("ARRAY[[2, 3, 1]]::bigint[]"), "Should preserve complex array with multiple values"
  end
end
