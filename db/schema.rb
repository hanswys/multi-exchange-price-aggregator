# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_26_081747) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "timescaledb"
  enable_extension "timescaledb_toolkit"

  create_table "ticks", id: false, force: :cascade do |t|
    t.string "exchange", null: false
    t.timestamptz "ingested_ts", null: false
    t.string "pair", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.decimal "quote_volume_24h", precision: 28, scale: 8, null: false
    t.timestamptz "source_ts", null: false
    t.index ["exchange", "pair", "ingested_ts"], name: "idx_ticks_lookup", order: { ingested_ts: :desc }
    t.index ["ingested_ts"], name: "ticks_ingested_ts_idx", order: :desc
  end
end
