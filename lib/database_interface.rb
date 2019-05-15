module Nerve
  module DatabaseInterface
    def db
      return @db if @db
      @db = SQLite3::Database.new(table_file)
      @db.type_translation = true
      @db
    end

    def normalize_params(args)
      args.map do |arg|
        case arg
        when TrueClass
          "true"
        when FalseClass
          "false"
        when Symbol
          arg.to_s
        when Time
          arg.gmtime.strftime("%Y-%m-%d %H:%M:%S.%L")
        else
          arg
        end
      end
    end

    def db_query(sql, *args)
      nargs = normalize_params(args)
      return db.execute(sql, *nargs) unless sql.downcase.start_with?("select")
      columns, *rows = db.execute2(sql, *nargs)
      rows.map do |row|
        row_hash = {}
        row.each_with_index do |value, idx|
          row_hash[columns[idx].to_sym] = value
        end
        row_hash
      end
    end

    def exists?
      File.exists?(table_file)
    end

    def table_file
      File.join(ENV["DATADIR"] || "data", table_name + ".db")
    end

    def primary_key
      (table_name + "_id").to_sym
    end
  end
end
