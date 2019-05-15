module Nerve
  class Endpoint
    include Nerve
    class << self
      include DatabaseInterface

      def scan
        create! unless exists?
        @endpoints = {}
        db_query("select * from #{table_name}")
          .map { |row| self.new(row) }
          .each { |ep| @endpoints[ep.path] = ep }
        @endpoints
      end

      def all
        scan if @endpoints.nil?
        @endpoints.values
      end

      def named(path)
        scan if @endpoints.nil?
        @endpoints[path]
      end

      def delete(path)
        existing = named(path)
        @endpoints.delete(path)
        existing.delete! if existing
      end

      def add(params={})
        if existing = named(params[:path]) then
          existing.update(params)
          return existing
        end

        @endpoints[params[:path]] = self.new.create(params)
      end

      def create!
        db_query <<-SQL
          create table #{table_name} (
            endpoint_id integer primary key,
            create_time timestamp default (strftime('%Y-%m-%d %H:%M:%f', 'NOW')),
            
            path varchar(255) not null,

            logged boolean not null default false,
            max_log_age_ms integer,
            max_log_count integer,
            min_log_spacing_s integer,
            poll_interval_ms integer,

            datatype varchar(255) not null default "text",
            source text not null default "keystore",
            
            value text,
            last_update timestamp,
            last_change timestamp
          )
        SQL
      end

      def table_name
        "endpoint"
      end
    end

    attr_accessor :path, :id, :last_update, :last_change, :poll_interval_ms,
      :max_log_count, :max_log_age_ms, :source, :datatype, :min_log_spacing_s,
      :logged, :create_time

    def initialize(params={})
      set_params(params)
    end

    def keys
      [ :endpoint_id, :path, :logged, :max_log_count, :max_log_age_ms,
        :poll_interval_ms, :datatype, :source, :value, :last_update,
        :last_change, :create_time, :min_log_spacing_s ]
    end

    def create(params={})
      used_keys = keys.select { |key| params.has_key?(key) }
      values = used_keys.map { |key| params[key] }
      db_query("insert into #{self.class.table_name} " +
        "(" + used_keys.join(", ") + ") values " +
        "(" + values.map { |v| "?" }.join(", ") + ")",
        *values)
      @id = db_query("select endpoint_id from #{self.class.table_name} " +
        "where path=? order by endpoint_id desc limit 1",
        params[:path]).first[:endpoint_id]
      refresh
      self
    end

    def refresh
      params = db_query("select * from #{self.class.table_name} where endpoint_id=?", id).first
      set_params(params)
    end

    def update(params={})
      used_keys = keys.select { |key| params.has_key?(key) }
      values = used_keys.map { |key| params[key] }
      db_query("update #{self.class.table_name} set " +
        used_keys.map { |key| "#{key}=?" }.join(", "),
        *values)
      set_params(params)
    end

    def key_map
      {
        endpoint_id: :id,
      }
    end

    def map_key(key)
      key_map[key] || key
    end

    def set_params(params={})
      params
        .keys
        .select { |key| self.respond_to?(:"#{map_key(key)}=") }
        .reject { |key| [:value].include?(map_key(key)) }
        .each { |key| self.send(:"#{map_key(key)}=", params[key]) }

      if params[:poll_interval_ms] && params[:poll_interval_ms] > 0 then
        PollMonitor.shared
      end

      @last_value = params[:value] if params.has_key?(:value)
    end

    def delete!
      db_query("delete from #{self.class.table_name} where endpoint_id=?", id)
      callbacks.each do |cb|
        cb.delete!
      end

      self.class.delete(path)
    end

    def logged?
      @logged
    end

    def stale?
      source != "keystore" \
        && poll_interval_ms \
        && poll_interval_ms > 0 \
        && (last_update.nil? || Time.now - last_update > poll_interval_ms)
    end

    def db_query(sql, *args)
      self.class.db_query(sql, *args)
    end

    def convert_value(str_value)
      return str_value unless str_value.is_a?(String)
      case datatype
      when :timestamp
        if str_value.match(/^(\d+\.)?\d+$/) then
          Time.at(str_value.to_f)
        else
          Time.parse(str_value)
        end
      when :integer
        str_value.to_i
      when :real
        str_value.to_f
      when :json
        begin
          JSON.parse(str_value)
        rescue JSON::ParserError => exc
          log_error("Endpoint #{path}: unable to parse JSON value #{str_value}; defaulting to nil", exc)
          nil
        end
      else
        str_value
      end
    end

    def value
      case source
      when nil, "keystore"
        @last_value
      when /^https?:\/\//
        self.value = web(:get, source)
      else
        self.value = command(source)
      end
    end

    def value=(new_value)
      changed = new_value != @last_value
      @last_value = convert_value(new_value)

      log_value(new_value) if logged?
      run_callbacks(new_value, changed)
      update_stored_value(new_value, changed)

      @last_value
    end

    def run_callbacks(new_value, changed)
      Callback.for_endpoint(self).each do |callback|
        log "#{path}: Performing callback '#{callback.method} #{callback.url}', type=#{callback.type}, changed=#{changed}"
        callback.call(new_value) if changed || callback.type == "update"
      end
    end

    def datalog
      @datalog ||= EndpointDatalog.new(self)
    end

    def log_value(new_value)
      datalog.add_entry(new_value)
    end

    def update_stored_value(new_value, changed)
      @last_update = Time.now
      @last_change = Time.now if changed

      log "#{path}: set value #{new_value}, changed=#{changed}"

      case source
      when "keystore"
        update_keystore(new_value, changed)
      else
        update_passthru(new_value, changed)
      end
    end

    def update_keystore(new_value, changed)
      sql = if changed then
        "update #{self.class.table_name} set value=?, last_update = (strftime('%Y-%m-%d %H:%M:%f', 'NOW')), last_change = (strftime('%Y-%m-%d %H:%M:%f', 'NOW'))"
      else
        "update #{self.class.table_name} set value=?, last_update = (strftime('%Y-%m-%d %H:%M:%f', 'NOW'))"
      end

      db_query(sql, new_value.to_s)
    end

    def update_passthru(new_value, changed)
      # for scripts and URLs, only update the record on change.
      # this is meant to prevent excessive IOPS on rapid scans
      update_keystore(new_value, changed) if changed
    end

    def callbacks
      Callback.for_endpoint(self)
    end

    def add_callback(method, url, type=:update)
      Callback.add(self, method, url, type)
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    def to_h
      h = {}
      keys
        .map { |key| key_map[key] || key }
        .each { |key| h[key] = self.send(key) }
      h[:callbacks] = callbacks.map { |cb| cb.to_h }
      h.keys.each { |k| h.delete(k) if h[k].nil? }
      h
    end
  end
end
