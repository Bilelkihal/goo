module SOLR
  module Query

    def clear_all_data
      delete_by_query('*:*')
    end

    def collection_url
      "#{@solr_url}/#{@collection_name}"
    end

    def index_commit(attrs = nil)
      @solr.commit(:commit_attributes => attrs || {})
    end

    def index_optimize(attrs = nil)
      @solr.optimize(:optimize_attributes => attrs || {})
    end

    def index_document(document, commit: true)
      @solr.add(document)
      @solr.commit if commit
    end

    def index_document_attr(key, type, is_list, fuzzy_search)
      dynamic_field(type: type, is_list: is_list, is_fuzzy_search: fuzzy_search).gsub('*', key.to_s)
    end

    def delete_by_id(document_id, commit: true)
      return if document_id.nil?

      @solr.delete_by_id(document_id)
      @solr.commit if commit
    end

    def delete_by_query(query)
      @solr.delete_by_query(query)
      @solr.commit
    end

    def search(query, params = {})
      params[:q] = query
      @solr.get('select', params: params)
    end

    def submit_search_query(query, params = {})
      uri = ::URI.parse("#{collection_url}/select")

      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Post.new(uri.request_uri)

      params[:q] = query
      request.set_form_data(params)

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      else
        puts "Error: #{response.code} - #{response.message}"
        nil
      end
    end

    private

    def dynamic_field(type:, is_list:, is_fuzzy_search: false)
      return is_list ? '*_texts' : '*_text' if is_fuzzy_search

      dynamic_type = case type
                     when :uri, :string, nil
                       '*_t'
                     when :integer
                       '*_i'
                     when :boolean
                       '*_b'
                     when :date_time
                       '*_dt'
                     when :float
                       '*_f'
                     else
                       # Handle unknown data types or raise an error based on your specific requirements
                       raise ArgumentError, "Unsupported ORM data type: #{type}"
                     end

      if is_list
        dynamic_type = dynamic_type.eql?('*_t') ? "*_txt" : "#{dynamic_type}s"
      end

      dynamic_type
    end
  end
end

