# frozen_string_literal: true

# Schema with large JSON columns, several existing indexes, a nullifying parent FK, and
# inbound child FKs; used to test adding partial and covering reporting indexes.
module JobReportingSchema
  def self.install(connection)
    connection.instance_eval do
      create_table(:projects) { |table| table.string :title }
      create_table "jobs", force: :cascade do |t|
        t.integer "attempt"
        t.json "arguments"
        t.integer "attempts_count", default: 0
        t.text "backtrace"
        t.datetime "created_at", null: false
        t.integer "duration_ms"
        t.string "error_message"
        t.boolean "exclusive", default: false, null: false
        t.string "failure_reason"
        t.json "headers"
        t.integer "lock_version", default: 0
        t.json "metadata", default: {}
        t.json "payload", default: {}
        t.integer "priority", default: 0
        t.integer "progress", default: 0
        t.bigint "project_id"
        t.string "queue_name"
        t.boolean "recurring", default: false, null: false
        t.json "result", default: {}
        t.integer "retry_limit", default: 0
        t.string "status"
        t.datetime "updated_at", null: false
        t.decimal "weight", precision: 10, scale: 6
        t.index [ "project_id", "status", "updated_at" ], name: "index_jobs_on_project_status_updated_at"
        t.index [ "project_id" ], name: "index_jobs_on_project_id"
        t.index [ "created_at" ], name: "index_jobs_on_created_at"
        t.index [ "status", "created_at" ], name: "index_jobs_on_status_and_created_at"
      end
      add_foreign_key :jobs, :projects, on_delete: :nullify
      create_table(:job_steps) { |table| table.bigint :job_id }
      add_foreign_key :job_steps, :jobs
      create_table(:job_attempts) { |table| table.bigint :job_id }
      add_foreign_key :job_attempts, :jobs
    end
  end
end
