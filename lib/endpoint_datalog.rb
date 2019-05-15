module Nerve
  class EndpointDatalog
    include DatabaseInterface

    attr_reader :endpoint

    def initialize(endpoint)
      @endpoint = endpoint
    end

    def table_datatype
      case endpoint.datatype
      when :json
        :text
      else
        endpoint.datatype
      end
    end

    def create!
      db_query <<-SQL
        create table #{table_name} (
          log_id integer primary key,
          record_time datetime default (strftime('%Y-%m-%d %H:%M:%f', 'NOW')),
          value #{table_datatype}
        )
      SQL
    end

    def table_name
      @endpoint
        .path
        .downcase
        .gsub(/^[^a-zA-Z0-9_]+/, "")
        .gsub(/[^a-zA-Z0-9_]+/, "_") + "_log"
    end

    def add_entry(value)
      create! unless exists?
      if endpoint.min_log_spacing_s then
        last_entry_time = (latest(1).first || {})[:record_time] || Time.at(0)
        elapsed = Time.now - last_entry_time
        return unless elapsed >= endpoint.min_log_spacing_s
      end

      db_query("insert into #{table_name} (value) values (?)",
        value)
      prune!
    end

    def primary_key
      :log_id
    end

    def prune!
      prune_to_age! if endpoint.max_log_age_ms
      prune_to_count! if endpoint.max_log_count
    end

    def prune_to_age!
      cutoff = Time.now - 0.001*endpoint.max_log_age_ms
      db_query("delete from #{table_name} where record_time < ?", cutoff)
    end

    def prune_to_count!
      cutoff_row = db_query("select log_id from #{table_name} order by log_id desc limit ? offset ?",
        endpoint.max_log_count, endpoint.max_log_count-1).first
      return unless cutoff_row
      cutoff = cutoff_row[:log_id]
      db_query("delete from #{table_name} where log_id < ?", cutoff)
    end

    def all
      db_query("select * from #{table_name}")
    end

    def earliest(count)
      db_query("select * from #{table_name} asc limit ?", count)
    end

    def latest(count)
      db_query("select * from #{table_name} desc limit ?", count)
    end

    def after(id, count)
      db_query("select * from #{table_name} where #{primary_key} > ? asc limit ?",
        id, count)
    end

    def after_time(time, count)
      db_query("select * from #{table_name} where record_time > ? asc limit ?",
        time, count)
    end

    def before(id, count)
      db_query("select * from #{table_name} where #{primary_key} < ? desc limit ?",
        id, count)
    end

    def before_time(time)
      db_query("select * from #{table_name} where record_time < ? desc limit ?",
        time, count)
    end

    def scrub!
      File.unlink(table_file) if exists?
    end
  end
end
