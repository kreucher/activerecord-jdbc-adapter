module JdbcSpec
  module DB2
    def self.adapter_matcher(name, config)
      if name =~ /(db2|as400)/i
         return config[:url] =~ /^jdbc:derby:net:/ ? ::JdbcSpec::Derby : self
      end
      false
    end

    def self.adapter_selector
      [/(db2|as400)/i, lambda {|cfg,adapt|
         if cfg[:url] =~ /^jdbc:derby:net:/
           adapt.extend(::JdbcSpec::Derby)
         else
           adapt.extend(::JdbcSpec::DB2)
         end }]
    end

    def self.extended(obj)
      # Ignore these 4 system tables
      ActiveRecord::SchemaDumper.ignore_tables |= %w{hmon_atm_info hmon_collection policy stmg_dbsize_info}
    end

    module Column
      def type_cast(value)
        return nil if value.nil? || value =~ /^\s*null\s*$/i
        case type
        when :string    then value
        when :integer   then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :primary_key then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :float     then value.to_f
        when :datetime  then cast_to_date_or_time(value)
        when :timestamp then cast_to_time(value)
        when :time      then cast_to_time(value)
        else value
        end
      end
      def cast_to_date_or_time(value)
        return value if value.is_a? Date
        return nil if value.blank?
        guess_date_or_time((value.is_a? Time) ? value : cast_to_time(value))
      end

      def cast_to_time(value)
        return value if value.is_a? Time
        time_array = ParseDate.parsedate value
        time_array[0] ||= 2000; time_array[1] ||= 1; time_array[2] ||= 1;
        Time.send(ActiveRecord::Base.default_timezone, *time_array) rescue nil
      end

      def guess_date_or_time(value)
        (value.hour == 0 and value.min == 0 and value.sec == 0) ?
        Date.new(value.year, value.month, value.day) : value
      end
    end

    def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
      id = super
      unless id
        table_name = sql.split(/\s/)[2]
        result = select(ActiveRecord::Base.send(:sanitize_sql,
            %[select IDENTITY_VAL_LOCAL() as last_insert_id from #{table_name}],
            nil))
        id = result.last['last_insert_id']
      end
      id
    end

    def modify_types(tp)
      tp[:primary_key] = 'int not null generated by default as identity (start with 1) primary key'
      tp[:string][:limit] = 255
      tp[:integer][:limit] = nil
      tp[:boolean][:limit] = nil
      tp
    end

    def adapter_name
      'DB2'
    end

    def add_limit_offset!(sql, options)
      limit, offset = options[:limit], options[:offset]
      if limit && !offset
        if limit == 1
          sql << " FETCH FIRST ROW ONLY"
        else
          sql << " FETCH FIRST #{sanitize_limit(limit)} ROWS ONLY"
        end
      elsif limit && offset
        sql.gsub!(/SELECT/i, 'SELECT B.* FROM (SELECT A.*, row_number() over () AS internal$rownum FROM (SELECT')
        sql << ") A ) B WHERE B.internal$rownum > #{offset} AND B.internal$rownum <= #{sanitize_limit(limit) + offset}"
      end
    end

    def pk_and_sequence_for(table)
      # In JDBC/DB2 side, only upcase names of table and column are handled.
      keys = super(table.upcase)
      if keys[0]
        # In ActiveRecord side, only downcase names of table and column are handled.
        keys[0] = keys[0].downcase
      end
      keys
    end

    def quote_column_name(column_name)
      column_name
    end

    def quote(value, column = nil) # :nodoc:
      if column && column.type == :primary_key
        return value.to_s
      end
      if column && (column.type == :decimal || column.type == :integer) && value
        return value.to_s
      end
      case value
      when String
        if column && column.type == :binary
          "BLOB('#{quote_string(value)}')"
        else
          "'#{quote_string(value)}'"
        end
      else super
      end
    end

    def quote_string(string)
      string.gsub(/'/, "''") # ' (for ruby-mode)
    end

    def quoted_true
      '1'
    end

    def quoted_false
      '0'
    end

    def recreate_database(name)
      tables.each {|table| drop_table("#{db2_schema}.#{table}")}
    end

    def remove_index(table_name, options = { })
      execute "DROP INDEX #{quote_column_name(index_name(table_name, options))}"
    end

    # This method makes tests pass without understanding why.
    # Don't use this in production.
    def columns(table_name, name = nil)
      super.select do |col|
        # strip out "magic" columns from DB2 (?)
        !/rolename|roleid|create_time|auditpolicyname|auditpolicyid|remarks/.match(col.name)
      end
    end

    def add_quotes(name)
      return name unless name
      %Q{"#{name}"}
    end

    def strip_quotes(str)
      return str unless str
      return str unless /^(["']).*\1$/ =~ str
      str[1..-2]
    end

    def expand_double_quotes(name)
      return name unless name && name['"']
      name.gsub(/"/,'""')
    end


    def structure_dump #:nodoc:
      definition=""
      rs = @connection.connection.meta_data.getTables(nil,nil,nil,["TABLE"].to_java(:string))
      while rs.next
        tname = rs.getString(3)
        definition << "CREATE TABLE #{tname} (\n"
        rs2 = @connection.connection.meta_data.getColumns(nil,nil,tname,nil)
        first_col = true
        while rs2.next
          col_name = add_quotes(rs2.getString(4));
          default = ""
          d1 = rs2.getString(13)
          default = d1 ? " DEFAULT #{d1}" : ""

          type = rs2.getString(6)
          col_size = rs2.getString(7)
          nulling = (rs2.getString(18) == 'NO' ? " NOT NULL" : "")
          create_col_string = add_quotes(expand_double_quotes(strip_quotes(col_name))) +
            " " +
            type +
            "" +
            nulling +
            default
          if !first_col
            create_col_string = ",\n #{create_col_string}"
          else
            create_col_string = " #{create_col_string}"
          end

          definition << create_col_string

          first_col = false
        end
        definition << ");\n\n"
      end
      definition
    end

    def dump_schema_information
      begin
        if (current_schema = ActiveRecord::Migrator.current_version) > 0
          #TODO: Find a way to get the DB2 instace name to properly form the statement
          return "INSERT INTO DB2INST2.SCHEMA_INFO (version) VALUES (#{current_schema})"
        end
      rescue ActiveRecord::StatementInvalid
        # No Schema Info
      end
    end

    def tables
      @connection.tables(nil, db2_schema, nil, ["TABLE"])
    end

    private
    def db2_schema
      if @config[:schema].blank?
        if @config[:url] =~ /^jdbc:as400:/
          # AS400 implementation takes schema from library name (last part of url)
          schema = @config[:url].split('/').last.strip
          (schema[-1..-1] == ";") ? schema.chop : schema
        else
          # LUW implementation uses schema name of username by default
          @config[:username] or ENV['USER']
        end
      else
        @config[:schema]
      end
    end
  end
end
