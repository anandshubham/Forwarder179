module Fluent

	## Gem imports
	require 'rubygems'
	require 'json'
	require 'fileutils'
	require 'rsolr'
	require 'mongo'
	require 'redis'

	## Local imports
	require 'fluent/plugin/in_tail'
	require 'fluent/mixin/config_placeholders'


	class SolrTailInput < NewTailInput

		## Register the plugin
		Plugin.register_input('solrtail', self)

		## Define custom parameters
		# vijay desc'Solr server address'
		config_param :solr_address, :string, :default => ''

		# vijay desc'Solr proxy address'
		config_param :solr_proxy, :string, :default => ''

		# vijay desc'Field name from the log entries whose value has to be used to query solr'
		config_param :identifier, :string, :default => ''

		# vijay desc'Identifier key that will be used against identifier value to query solr'
		config_param :identifier_key, :string, :default => ''

		# vijay desc'Chunk size to read from solr'
		config_param :chunk_size, :integer, :default => 100

		# vijay desc'Solr tail log file full path'
		config_param :log_file, :string, :default => '/var/log/solrtail/solrtail.log'

		# vijay desc'Solr required fields (comma separated)'
		config_param :required_fields, :string, :default => ''

		# vijay desc'List of fields to replace with nil if these are blank strings'
		config_param :replace_with_nil, :string, :default => ''

		# vijay desc'Enables mongo data merger'
		config_param :mongo_merge_enabled, :bool, :default => false

		# vijay desc'Mongo servers IP Address'
		config_param :mongo_address, :string, :default => ''

		# vijay desc'Mongo servers port'
		config_param :mongo_port, :string, :default => '27017'

		# vijay desc'Mongo Database name to be used while querying'
		config_param :mongo_db, :string, :default => ''

		# vijay desc'Mongo collection type to query in'
		config_param :mongo_collection_type, :string, :default => ''

		# vijay desc'Mongo server user name'
		config_param :mongo_user, :string, :default => ''

		# vijay desc'Mongo server password'
		config_param :mongo_password, :string, :default => ''

		# vijay desc'Mongo comma separated list of fields to fetch from mongo'
		config_param :mongo_projection_keys, :string, :default => ''

		# vijay desc'key that will be used query mongo'
		config_param :mongo_query_key, :string, :default => ''

		# vijay desc'keys used to match records between mongo and solr separated by "::"'
		config_param :mongo_match_by, :string, :default => ''

        # vijay desc'Field to be fetched from mongo documents and their solr keys'
        config_param :mongo_fields, :array, :default => []

        # vijay desc'Redis host address'
        config_param :redis_host, :string, :default => '127.0.0.1'

        # vijay desc'Redis port'
        config_param :redis_port, :string, :default => '6379'

        # vijay desc'Redis DB'
        config_param :redis_db, :integer, :default => 1


		def is_num(x)
			true if Float(x) rescue false
		end

		## Override configure to validate custom parameters
		def configure(conf)
			super

			@identifier_array = Array.new
            @not_found = Array.new
            @require_merge = Array.new
            @redis = Redis.new(:host => @redis_host, :port => @redis_port, :db => 1)

			if @identifier.empty?
				raise ConfigError, 'Please specify the field identifier to pick value from a log entry'
			end
			if @identifier_key.empty?
				raise ConfigError, 'Please specify an identifier key to query solr'
			end
			if @solr_address.empty?
				raise ConfigError, 'Please specify the solr server address'
			end
			if @required_fields.empty?
               raise ConfigError, 'Please specify required fields.'
            end

			if @solr_proxy.empty?
				@solr = RSolr.connect :url => @solr_address
            else
				@solr = RSolr.connect :url => @solr_address, :proxy => @solr_proxy
            end
			##solrtail log file to log results.
			begin
                FileUtils.mkdir_p File.dirname(@log_file), :mode => 755
				file = File.open(@log_file, "a")
			rescue IOError => e
				raise ConfigError, e
			ensure
				file.close unless file.nil?
			end

			## Test mongo merger configuration
			if @mongo_merge_enabled

				## Make sure we have mongo server IP
				if @mongo_address.empty?
					raise ConfigError, 'Please specify mongo server IP to connect to mongo'
				end
				if @mongo_address.include? ":"
					raise ConfigError, 'Please specify port using "mongo_port" configuration param'
				end

				## Make sure we have a database to workon
				if @mongo_db.empty?
					raise ConfigError, 'Please specify a mongo database to query on using "mongo_db" config param'
				end

				## Creating a global mongo client connection
				@mongo_client = Mongo::Client.new(["#{@mongo_address}:#{@mongo_port}"], :database => @mongo_db, :user => @mongo_user, :password => @mongo_password, :connect => :direct)

				if @mongo_match_by.empty?
					raise ConfigError, 'Can not match records without the matching keys specified'
				end
			end
		end

		## Oveerride convert lines method to implement
		## a hook to solr to get extra record information
		## from solr.
		def convert_line_to_event(line, es)
			begin
				line.chomp!  # remove \n
				@parser.parse(line) { |time, record|
					if time && record
						es.add(time, record)
                        identifier = record[@identifier].gsub(/\s+/, '')
                        if !@redis.get identifier
                            @redis.set identifier, true
                            @redis.expire identifier, 60*60*24*45
                            get_additional_data(identifier)
                        end
                    else
						log.warn "pattern not match"
					end
				}
			rescue => e
				log.warn line.dump, :error => e.to_s
				log.debug_backtrace(e.backtrace)
			end
		end

        ## Get the additional data required to push to the
        ## the new log file.
        def get_additional_data(identifier)
            if identifier && identifier.length > 4
                ## push only unique values
                if !@identifier_array.include? "#{identifier}"
                    @identifier_array.push("#{identifier}")
                end

                ## Get data from solr and merge
                resp = get_from_solr
                if !resp.nil?
                    coll = get_extra_from_mongo
                    mresp = merge_mongo_and_solr(coll, resp)
                    log_from_response(mresp['response']['docs'])
                end

                ## Get data from mongodb
                moresp = get_from_mongo
                if !moresp.nil?
                    log_from_response(moresp)
                end
            end
        end

		## Given an array of string ids, This method differentiates between
		## mongo object ids and regular sql ids and return an array of ids
		## that is readable by mongo client.
		def get_mongo_ids(idarray)
			results = []
			for id in idarray
				if is_num(id)
					results.push(id)
				else
					results.push(BSON::ObjectId.from_string(id))
				end
			end
		end

        ## Get's the required data from the solr server
		def get_from_solr
            if @identifier_array.size >= chunk_size
                begin
                    query_value = @identifier_array.join(" ")
                    resp = @solr.get 'select', :params => {:q => "#{identifier_key}:( #{query_value} )", :fl => "#{required_fields}", :rows => "#{chunk_size}"}
                        @identifier_array.each do |id|
                            if resp["response"]["docs"].find_index {|item| item["#{identifier_key}"] == "#{id}"}
                                if !@require_merge.include? "#{id}"
                                    @require_merge.push(id)
                                end
                            else
                                if !@not_found.include? "#{id}"
                                    @not_found.push(id)
                                end
                            end
                        end
                    return resp
                rescue => e
                    log.error "#{e}"
                ensure
                    @identifier_array.clear
                end
            end
		end

		## Given an array of mongo ids this method will return a collection
		## of mongo documents found based on the ids array. Call this method
		## in batches for performance purposes.
		def get_extra_from_mongo
            ids = @require_merge.join(",").split(",")
			collection = @mongo_client[:"#{mongo_collection_type}"].find(:"#{mongo_query_key}" => {:$in => ids})
			if !@mongo_projection_keys.empty?
				pkeys = {}
				for key in @mongo_projection_keys.split(",")
					pkeys[key] = 1
				end
				collection = collection.projection(pkeys)
			end
            @require_merge.clear
			return collection
		end

        def get_from_mongo
            if @not_found.size >= chunk_size
                begin
                    results = Array.new
                    ids = @not_found.join(",").split(",")
                    collection = @mongo_client[:"#{mongo_collection_type}"].find(:"#{mongo_query_key}" => {:$in => ids})
                    collection.each do |document|
                        object = {}
                        for field in @mongo_fields
                            if field[0].is_a? Array
                                value = ""
                                field[0].each do |subfield|
                                    if document.has_key?(:"#{subfield}")
                                        if subfield == 'sl'
                                            fieldvalue = "#{document.fetch(subfield)}"
                                            if fieldvalue
                                                fieldvalue = Integer(fieldvalue)
                                                value = "Rs #{fieldvalue} - #{fieldvalue += 1} Lacs"
                                            else
                                                value = ""
                                            end
                                        elsif subfield == 'st'
                                            nil
                                        else
                                            value += "#{document.fetch(subfield)} "
                                        end
                                    end
                                end
                                object[field[1]] = value.strip
                            else
                                if document.has_key?(:"#{field[0]}")
                                    object[field[1]] = document.fetch(field[0])
                                end
                            end
                        end
                        results.push(object)
                    end
                    @not_found.clear
                    return results
                rescue => e
                    log.error "#{e}"
                end
            end
        end

		## puts the mongo projection keys to the solr objects if there is
		## a match by defined keys.
		def merge_mongo_and_solr(collection, resp)
			solr_objects = resp['response']['docs']
			mkey,skey = @mongo_match_by.split("::")
            collection.each_with_index do |document,index|
				mid = document.fetch("#{mkey}")
                sdoc = solr_objects.find {|sd| sd["#{skey}"] == "#{mid}"}
                for pkey in @mongo_projection_keys.split(",")
                    if document.has_key?("#{pkey}")
                        sdoc["#{pkey}"] = document.fetch("#{pkey}")
                    end
                end
            end
			resp['response']['docs'] = solr_objects
			return resp
		end

		## Logs the data to the out put file using the given response.
		def log_from_response response
            begin
                aFile = File.new(@log_file, "a")
                    for object in response
                        if !@replace_with_nil.empty?
                            for rfield in @replace_with_nil.split(",")
                                if object.has_key?(rfield) && object[rfield] == ""
                                    object[rfield] = nil
                                end
                            end
                        end
                        aFile.syswrite("#{object.to_json}\n")
                    end
            rescue => e
                log.error e.to_s
                log.debug_backtrace(e.backtrace)
            ensure
                aFile.close
            end
		end
	end
end
