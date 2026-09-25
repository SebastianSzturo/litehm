# frozen_string_literal: true

require "litehm"

path = ARGV.fetch(0)
point = ARGV.fetch(1).to_sym
plan = LiteHM.plan(:messages, id: "process-crash", connection: path,
  policy: { lease_ttl_ms: 20 }) do |table|
  table.add_column :flag, :integer, null: false, default: 0
end

LiteHM::Testing.fault_injector = lambda do |observed, _context|
  Process.kill("KILL", Process.pid) if observed == point
end
LiteHM.run(plan)
