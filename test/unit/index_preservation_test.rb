# frozen_string_literal: true

require_relative '../test_helper'

class IndexPreservationTest < Minitest::Test
  def test_quoting_and_spacing_do_not_change_index_identity
    assert_equal signature("CREATE INDEX ix ON messages(sent_at) WHERE body='hello'"),
      signature(%q{CREATE INDEX "ix" ON "messages" ("sent_at") WHERE "body" = 'hello'})
    assert_equal signature('CREATE INDEX ix ON messages(lower(body))'),
      signature(%q{CREATE INDEX "ix" ON "messages" (lower("body"))})
  end

  def test_sql_values_operators_and_quoted_keywords_remain_distinct
    [["body='a b'", "body='ab'"], ["body='HELLO'", "body='hello'"],
      ['sent_at>=1', 'sent_at>1'], ['sent_at+1', 'sent_at-1'],
      ['"null" IS NULL', 'NULL IS NULL'], ['sent_at||body', 'sent_at|body']].each do |left, right|
      refute_equal signature("CREATE INDEX ix ON messages(sent_at) WHERE #{left}"),
        signature("CREATE INDEX ix ON messages(sent_at) WHERE #{right}"), "#{left} / #{right}"
    end
  end

  private

  def signature(sql)
    compiler = LiteHM::ScratchCompiler.new(source: {}, target: nil, adapter_name: 'sqlite3')
    compiler.send(:normalized_index_sql, sql, %w[sent_at body])
  end
end
