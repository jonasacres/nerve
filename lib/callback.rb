module Nerve
  class Callback
    include Nerve
    class << self
      include DatabaseInterface

      def named(endpoint)
        @endpoints[endpoint] ||= self.new(endpoint)
      end

      def create!
        db_query <<-SQL
          create table #{table_name} (
            callback_id integer primary key,
            create_time timestamp default (strftime('%Y-%m-%d %H:%M:%f', 'NOW')),
            
            endpoint_id integer not null,
            method varchar(255) not null default "post",
            url text not null,
            type varchar(255) not null default "update"
          )
        SQL
      end

      def table_name
        "callback"
      end

      def for_endpoint(endpoint)
        create! unless exists?
        rows = db_query("select * from #{table_name} where endpoint_id=?",
          endpoint.id)
        rows.map { |row| self.new(endpoint, row) }
      end

      def add(endpoint, method, url, type="update")
        create! unless exists?
        db_query("insert into #{table_name} (endpoint_id, method, url, type) values (?, ?, ?, ?)",
          endpoint.id,
          method,
          url,
          type
          )
      end

      def delete(id)
        db_query("delete from #{table_name} where callback_id=?", id)
      end
    end

    attr_reader :url, :method, :id, :create_time, :type

    def initialize(endpoint, row)
      self.class.create! unless self.class.exists?
      @url = row[:url]
      @method = row[:method].downcase.to_sym || :post
      @id = row[:callback_id]
      @create_time = row[:create_time]
      @endpoint = endpoint
      @type = row[:type].downcase
    end

    def db_query(sql, *args)
      self.class.db_query(sql, *args)
    end

    def call(value)
      case @method
      when :get
        web(@method, @url)
      else
        web(@method, @url, value)
      end
    end

    def delete!
      db_query("delete from #{self.class.table_name} where callback_id=?",
        id)
    end

    def to_h
      {
        callback_id:id,
        method:method,
        url:url,
        type:type,
        create_time:create_time
      }
    end
  end
end
