require 'rsolr'
require_relative 'solr/solr_connector'

module Goo

  module Search

    def self.included(base)
      base.extend(ClassMethods)
    end

    def index(connection_name = nil, to_set = nil)
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      document = indexable_object(to_set)
      connection_name ||= self.class.search_collection_name
      unindex(connection_name)
      self.class.search_client(connection_name).index_document(document)
    end


    def unindex(connection_name = nil)
      connection_name ||= self.class.search_collection_name
      self.class.search_client(connection_name).delete_by_id(index_id)
    end

    # default implementation, should be overridden by child class
    def index_id
      raise ArgumentError, "ID must be set to be able to index" if @id.nil?
      @id.to_s
    end

    # default implementation, should be overridden by child class
    def index_doc(to_set = nil)
      raise NoMethodError, "You must define method index_doc in your class for it to be indexable"
    end

    def indexable_object(to_set = nil)
      begin
        document = index_doc(to_set)
      rescue
        document = self.to_hash.reject { |k, _| !self.class.indexable?(k) }
      end

      model_name = self.class.model_name.to_s.downcase
      document.delete(:id)
      document.delete("id")

      document.transform_keys! do |k|
        self.class.index_document_attr(k)
      end

      document[:resource_id] = self.id.to_s
      document[:resource_model] = model_name
      document[:id] = index_id.to_s
      document
    end

    module ClassMethods

      def enable_indexing(collection_name, search_backend = :main, &block)
        @model_settings[:search_collection] = collection_name

        if block_given?
          # optional block to generate custom schema
          Goo.add_search_connection(collection_name, search_backend, &block)
        else
          Goo.add_search_connection(collection_name, search_backend)
        end

        after_save :index
        after_destroy :unindex
      end

      def search_collection_name
        @model_settings[:search_collection]
      end

      def search_client(connection_name = search_collection_name)
        Goo.search_client(connection_name)
      end

      def custom_schema?(connection_name = search_collection_name)
        search_client(connection_name).custom_schema?
      end

      def schema_generator
        Goo.search_client(search_collection_name).schema_generator
      end

      def index_document_attr(key)
        return key.to_s if custom_schema?

        type = self.datatype(key)
        is_list = self.list?(key)
        fuzzy = self.fuzzy_searchable?(key)
        search_client.index_document_attr(key, type, is_list, fuzzy)
      end

      def search(q, params = {}, connection_name = search_collection_name)
        search_client(connection_name).search(q, params)
      end

      def indexBatch(collection, connection_name = search_collection_name)
        docs = collection.map(&:indexable_object)
        search_client(connection_name).index_document(docs)
      end

      def unindexBatch(collection, connection_name = search_collection_name)
        docs = collection.map(&:index_id)
        search_client(connection_name).delete_by_id(docs)
      end

      def unindexByQuery(query, connection_name = search_collection_name)
        search_client(connection_name).delete_by_query(query)
      end

      def indexCommit(attrs = nil, connection_name = search_collection_name)
        search_client(connection_name).index_commit(attrs)
      end

      def indexOptimize(attrs = nil, connection_name = search_collection_name)
        search_client(connection_name).optimize(attrs)
      end

      # WARNING: this deletes ALL data from the index
      def indexClear(connection_name = search_collection_name)
        search_client(connection_name).clear_all_data
      end
    end
  end
end
