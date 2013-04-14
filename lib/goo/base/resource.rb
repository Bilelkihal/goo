require 'cgi'
require_relative "settings/settings"

module Goo
  module Base

    class Resource
      include Goo::Base::Settings
      #include Goo::Search

      attr_reader :loaded_attributes
      attr_reader :modified_attributes
      attr_reader :errors

      attr_reader :id

      def initialize(*args)
        @loaded_attributes = Set.new
        @modified_attributes = Set.new
        @previous_values = nil
        @persistent = false || args[-1][:persistent]

        attributes = args[0] || {}
        opt_symbols = Goo.resource_options
        attributes.each do |attr,value|
          next if opt_symbols.include?(attr)
          self.send("#{attr}=",value)
        end

        @id = nil
      end

      def valid?
        validation_errors = {}
        self.class.attributes.each do |attr|
          inst_value = self.instance_variable_get("@#{attr}")
          attr_errors = Goo::Validators::Enforce.enforce(self,attr,inst_value)
          unless attr_errors.nil?
            validation_errors[attr] = attr_errors
          end
        end
        @errors = validation_errors.freeze

        unless @persistent
          uattr = self.class.unique_attribute
          if @errors[uattr].nil?
            begin
              @id = id_from_unique_attribute(uattr)
              if self.exist?(from_valid=true)
                uvalue = self.send("#{uattr}")
                @errors[uattr][:unique] = 
                  "There is already a persistent resource with `#{uattr}` value `#{uvalue}`"
              end
            rescue ArgumentError => e
              @errors[uattr][:unique] = e.message
            end 
          end
        end

        return @errors.length == 0
      end

      def id=(new_id)
        if !@id.nil? and @persistent
          raise ArgumentError, "The id of a persistent object cannot be changed."
        end
        raise ArgumentError, "ID must be an RDF::URI" unless new_id.kind_of?(RDF::URI)
        @id = new_id
      end

      def id
        return @id
      end

      def persistent?
        return @persistent
      end

      def modified?
        return modified_attributes.length > 0
      end

      def exist?(from_valid=false)
        _id = @id
        if _id.nil? and !from_valid
          uattr = self.class.unique_attribute
          _id = id_from_unique_attribute(uattr)
        end
        return Goo::SPARQL::Queries.model_exist(self,id=_id)
      end

      def delete
        raise ArgumentError, "This object is not persistent and cannot be deleted" if !@persistent
        graph_delete = Goo::SPARQL::Triples.model_delete_triples(self)
        begin
          Goo.sparql_update_client.delete_data(graph_delete, graph: self.class.uri_type)
        rescue Exception => e
          binding.pry
        end
        return nil
      end

      def save
        raise ArgumentError, "Object is not modified" unless modified?
        raise Goo::Base::NotValidException, "Object is not valid. Check errors." unless valid?

        graph_insert, graph_delete = Goo::SPARQL::Triples.model_update_triples(self)
        if graph_delete and graph_delete.size > 0
          begin
            Goo.sparql_update_client.delete_data(graph_delete, graph: self.class.uri_type)
          rescue Exception => e
            binding.pry
          end
        end
        if graph_insert and graph_insert.size > 0
          begin
            Goo.sparql_update_client.insert_data(graph_insert, graph: self.class.uri_type)
          rescue Exception => e
            binding.pry
          end
        end

        @modified_attributes = Set.new
        @persistent = true
        return self
      end

      def previous_values
        return @previous_values
      end

      protected
      def id_from_unique_attribute(attr)
        value_attr = self.send("#{attr}")
        if value_attr.nil?
          raise ArgumentError, "`#{attr}` value is nil. Id for resource cannot be generated."
        end
        uri_last_fragment = CGI.escape(value_attr)
        return self.class.namespace[self.class.model_name.to_s + '/' + uri_last_fragment]
      end
    end

  end
end
