require 'sparql/client'
require 'sparql/client/query'

module Goo
  module SPARQL
    module Queries

      BNODES_TUPLES = Struct.new(:id,:attribute)

      def self.sparql_op_string(op)
        case op
        when :or
          return "||"
        when :and
          return "&&"
        when :==
          return "="
        end
        return op.to_s
      end

      def self.expand_equivalent_predicates(query,eq_p)
        attribute_mappings = {}
        if eq_p && eq_p.length > 0
          count_rewrites = 0
          if query.options[:optionals]
            query.options[:optionals].each do |opt|
              opt.each do |pattern|
                if pattern.predicate && pattern.predicate.is_a?(RDF::URI)
                  if eq_p.include?(pattern.predicate.to_s)
                    if attribute_mappings.include?(pattern.predicate.to_s)
                      #reuse filter
                      pattern.predicate =
                        RDF::Query::Variable.new(attribute_mappings[pattern.predicate.to_s])
                    else
                      query_predicate = pattern.predicate
                      var_name = "rewrite#{count_rewrites}"
                      pattern.predicate = RDF::Query::Variable.new(var_name)
                      expansion = eq_p[query_predicate.to_s]
                      expansion = expansion.map { |x| "?#{var_name} = <#{x}>" }
                      expansion = expansion.join " || "
                      query.filter(expansion)
                      count_rewrites += 1
                      attribute_mappings[query_predicate.to_s] = var_name
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Expand equivalent predicate for attribute that are retrieved using filter (the new way to retrieve...)
      # i.e.: prefLabel can also be retrieved using the "http://data.bioontology.org/metadata/def/prefLabel" URI
      # so we add "http://data.bioontology.org/metadata/def/prefLabel" to the array_includes_filter that will generates a filter on property for meta:prefLabel
      # and we add the following entry to the uri_properties_hash: "http://data.bioontology.org/metadata/def/prefLabel" => "prefLabel"
      # So the object of http://data.bioontology.org/metadata/def/prefLabel will be retrieved and added to this attribute
      def self.expand_equivalent_predicates_filter(eq_p, array_includes_filter, uri_properties_hash)
        array_includes_filter_out = array_includes_filter.dup
        if eq_p && eq_p.length > 0
          if array_includes_filter
            array_includes_filter.each do |predicate_filter|
              if predicate_filter && predicate_filter.is_a?(RDF::URI)
                if eq_p.include?(predicate_filter.to_s)
                  eq_p[predicate_filter.to_s].each do |predicate_mapping|
                    pred_map_uri = RDF::URI.new(predicate_mapping)
                    array_includes_filter_out << pred_map_uri
                    uri_properties_hash[pred_map_uri] = uri_properties_hash[predicate_filter]
                  end
                end
              end
            end
          end
        end
        return array_includes_filter_out, uri_properties_hash
      end

      def self.duplicate_attribute_value?(model,attr,store=:main)
        value = model.instance_variable_get("@#{attr}")
        if !value.instance_of? Array
          so = Goo.sparql_query_client(store).ask.from(model.graph).
            whether([:id, model.class.attribute_uri(attr), value]).
            filter("?id != #{model.id.to_ntriples}")
          return so.true?
        else
          #not yet support for unique arrays
        end
      end

      def self.sub_property_predicates(*graphs)
        graphs = graphs.flatten!
        client = Goo.sparql_query_client(:main)
        select = client.select(:subP, :superP).distinct()
        select.where([:subP, Goo.vocabulary(:rdfs)[:subPropertyOf], :superP])
        select.from(graphs)
        tuples = []
        select.each_solution do |sol|
          tuples << [sol[:subP],sol[:superP]]
        end
        return tuples
      end

      def self.graph_predicates(*graphs)
        graphs = graphs.flatten
        client = Goo.sparql_query_client(:main)
        select = client.select(:predicate).distinct()
        select.where([:subject, :predicate, :object])
        select.from(graphs)
        predicates = []
        select.each_solution do |sol|
          predicates << sol[:predicate]
        end
        return predicates
      end

      def self.model_exist(model,id=nil,store=:main)
        id = id || model.id
        so = Goo.sparql_query_client(store).ask.from(model.graph).
          whether([id, RDF.type, model.class.uri_type(model.collection)])
        return so.true?
      end

      def self.query_filter_sparql(klass,filter,filter_patterns,filter_graphs,
                                   filter_operations,
                                   internal_variables,
                                   inspected_patterns,
                                   collection)
        #create a object variable to project the value in the filter
        filter.filter_tree.each do |filter_operation|
          filter_pattern_match = {}
          if filter.pattern.instance_of?(Symbol)
            filter_pattern_match[filter.pattern] = []
          else
            filter_pattern_match = filter.pattern
          end
          unless inspected_patterns.include?(filter_pattern_match)
            attr = filter_pattern_match.keys.first
            patterns_for_match(klass, attr, filter_pattern_match[attr],
                               filter_graphs, filter_patterns,
                                   [],internal_variables,
                                   subject=:id,in_union=false,in_aggregate=false,
                                   collection=collection)
            inspected_patterns[filter_pattern_match] = internal_variables.last
          end
          filter_var = inspected_patterns[filter_pattern_match]
          if !filter_operation.value.instance_of?(Goo::Filter)
            unless filter_operation.operator == :unbound || filter_operation.operator == :bound
              value = RDF::Literal.new(filter_operation.value)
              if filter_operation.value.is_a? String
                value = RDF::Literal.new(filter_operation.value, :datatype => RDF::XSD.string)
              end
              filter_operations << (
                "?#{filter_var.to_s} #{sparql_op_string(filter_operation.operator)} " +
                " #{value.to_ntriples}")
            else
              if filter_operation.operator == :unbound
                filter_operations << "!BOUND(?#{filter_var.to_s})"
              else
                filter_operations << "BOUND(?#{filter_var.to_s})"
              end
              return :optional
            end
          else
            filter_operations << "#{sparql_op_string(filter_operation.operator)}"
            query_filter_sparql(klass,filter_operation.value,filter_patterns,
                                filter_graphs,filter_operations,
                                internal_variables,inspected_patterns,collection)
          end
        end
      end

      def self.query_pattern(klass,attr,**opts)
        value = opts[:value] || nil
        subject = opts[:subject] || :id
        collection = opts[:collection] || nil
        value = value.id if value.class.respond_to?(:model_settings)
        if klass.attributes(:all).include?(attr) && klass.inverse?(attr)
          inverse_opts = klass.inverse_opts(attr)
          on_klass = inverse_opts[:on]
          inverse_klass = on_klass.respond_to?(:model_name) ? on_klass: Goo.models[on_klass]
          if inverse_klass.collection?(inverse_opts[:attribute])
            #inverse on collection - need to retrieve graph
            #graph_items_collection = attr
            #inverse_klass_collection = inverse_klass
            #return [nil, nil]
          end
          predicate = inverse_klass.attribute_uri(inverse_opts[:attribute],collection)
          return [ inverse_klass.uri_type(collection) ,
                   [ value.nil? ? attr : value, predicate, subject ]]
        else
          predicate = nil
          if attr.is_a?(Symbol)
            predicate = klass.attribute_uri(attr,collection)
          elsif attr.is_a?(RDF::URI)
            predicate = attr
          else
            raise ArgumentError, "Unknown attribute param for query `#{attr}`"
          end
          #unknown predicate
          return [klass.uri_type(collection),
                   [ subject , predicate , value.nil? ? attr : value]]
        end

      end

      def self.walk_pattern(klass, match_patterns, graphs, patterns, unions,
                                internal_variables,in_aggregate=false,query_options={},
                                collection)
        match_patterns.each do |match,in_union|
          unions << [] if in_union
          match = match.is_a?(Symbol) ? { match => [] } : match
          match.each do |attr,value|
            patterns_for_match(klass, attr, value, graphs, patterns,
                               unions,internal_variables,
                               subject=:id,in_union=in_union,
                               in_aggregate=in_aggregate,
                               query_options=query_options,
                               collection)
          end
        end
      end

      def self.add_rules(attr,klass,query_options)
        if klass.transitive?(attr)
          (query_options[:rules] ||=[]) << :SUBC
        end
      end

      def self.patterns_for_match(klass,attr,value,graphs,patterns,unions,
                                  internal_variables,subject=:id,in_union=false,
                                  in_aggregate=false,query_options={},collection=nil)
        if value.respond_to?(:each) || value.instance_of?(Symbol)
          next_pattern = value.instance_of?(Array) ? value.first : value

          #for filters
          next_pattern = { next_pattern => [] } if next_pattern.instance_of?(Symbol)

          value = "internal_join_var_#{internal_variables.length}".to_sym
          if in_aggregate
            value = "#{attr}_agg_#{in_aggregate}".to_sym
          end
          internal_variables << value
        end
        add_rules(attr,klass,query_options)
        graph, pattern =
          query_pattern(klass,attr,value: value,subject: subject, collection: collection)
        if pattern
          if !in_union
            patterns << pattern
          else
            unions.last << pattern
          end
        end
        graphs << graph if graph
        if next_pattern
          range = klass.range(attr)
          next_pattern.each do |next_attr,next_value|
            patterns_for_match(range, next_attr, next_value, graphs,
                  patterns, unions, internal_variables, subject=value,
                  in_union, in_aggregate, collection=collection)
          end
        end
      end

      ##
      # Call model_load_sliced to load a model from the triplestore
      def self.model_load(*options)
        options = options.last
        if options[:models] and options[:models].is_a?(Array) and\
                             options[:models].length > Goo.slice_loading_size
          options = options.dup
          models = options[:models]
          include_options = options[:include]
          models_by_id = Hash.new
          models.each_slice(Goo.slice_loading_size) do |model_slice|
            options[:models] = model_slice
            unless include_options.nil?
              options[:include] = include_options.dup
            end
            model_load_sliced(options)
            model_slice.each do |m|
              models_by_id[m.id] = m
            end
          end
          return models_by_id
        else
          return self.model_load_sliced(options)
        end
      end
      ##
      # always a list of attributes with subject == id
      ##

=begin
  Explanation why we need to change how the SPARQL queries are built:

  Example of a query built to get informations of submissions 2 of the MO ontologies

SELECT DISTINCT ?id ?submissionId ?prefLabelProperty ?definitionProperty ?synonymProperty ?authorProperty ?classType ?hierarchyProperty ?obsoleteProperty
?obsoleteParent ?homepage ?publication ?uri ?naturalLanguage ?documentation ?version ?creationDate ?description ?status ?released ?uploadFilePath
?diffFilePath ?masterFileName ?missingImports ?pullLocation ?metrics ?contact ?hasOntologyLanguage ?ontology ?submissionStatus
FROM <http://data.bioontology.org/metadata/OntologySubmission>
WHERE { ?id a <http://data.bioontology.org/metadata/OntologySubmission> . OPTIONAL { ?id <http://data.bioontology.org/metadata/submissionId> ?submissionId . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/prefLabelProperty> ?prefLabelProperty . } OPTIONAL { ?id <http://data.bioontology.org/metadata/definitionProperty> ?definitionProperty . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/synonymProperty> ?synonymProperty . } OPTIONAL { ?id <http://data.bioontology.org/metadata/authorProperty> ?authorProperty . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/classType> ?classType . } OPTIONAL { ?id <http://data.bioontology.org/metadata/hierarchyProperty> ?hierarchyProperty . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/obsoleteProperty> ?obsoleteProperty . } OPTIONAL { ?id <http://data.bioontology.org/metadata/obsoleteParent> ?obsoleteParent . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/homepage> ?homepage . } OPTIONAL { ?id <http://data.bioontology.org/metadata/publication> ?publication . }
OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#uri> ?uri . } OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#naturalLanguage> ?naturalLanguage . }
OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#documentation> ?documentation . } OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#version> ?version . }
OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#creationDate> ?creationDate . } OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#description> ?description . }
OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#status> ?status . } OPTIONAL { ?id <http://data.bioontology.org/metadata/released> ?released . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/uploadFilePath> ?uploadFilePath . } OPTIONAL { ?id <http://data.bioontology.org/metadata/diffFilePath> ?diffFilePath . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/masterFileName> ?masterFileName . } OPTIONAL { ?id <http://data.bioontology.org/metadata/missingImports> ?missingImports . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/pullLocation> ?pullLocation . } OPTIONAL { ?id <http://data.bioontology.org/metadata/metrics> ?metrics . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/contact> ?contact . } OPTIONAL { ?id <http://omv.ontoware.org/2005/05/ontology#hasOntologyLanguage> ?hasOntologyLanguage . }
OPTIONAL { ?id <http://data.bioontology.org/metadata/ontology> ?ontology . } OPTIONAL { ?id <http://data.bioontology.org/metadata/submissionStatus> ?submissionStatus . }
FILTER(?id = <http://data.bioontology.org/ontologies/MO/submissions/2>) }

  If there are only single value it is perfect, it returns a single result. But if there are multiple values for multiple attributes then the number of results is a
multiplication of the number of values for each attribute
  For example if we have 3 attributes with the following values:
attr1 = ["a1 value1", "a1 value2"]
attr2 = ["a2 value3", "a2 value4", a2 value5]
attr3 = ["a3 value6", "a3 value7"]
  We will got the following results:
"a1 value1", "a2 value3", "a3 value6"
"a1 value1", "a2 value4", "a3 value6"
"a1 value1", "a2 value5", "a3 value6"
"a1 value2",  "a2 value3", "a3 value6"
"a1 value2",  "a2 value4", "a3 value6"
"a1 value2",  "a2 value5", "a3 value6"
"a1 value1", "a2 value3", "a3 value7"
"a1 value1", "a2 value4", "a3 value7"
"a1 value1", "a2 value5", "a3 value7"
"a1 value2",  "a2 value3", "a3 value7"
"a1 value2",  "a2 value4", "a3 value7"
"a1 value2",  "a2 value5", "a3 value7"


  Here is the new query generated
SELECT DISTINCT ?id ?attributeProperty ?attributeObject FROM <http://data.bioontology.org/metadata/OntologySubmission>
WHERE { ?id a <http://data.bioontology.org/metadata/OntologySubmission> . OPTIONAL { ?id ?attributeProperty ?attributeObject . }
FILTER(?id = <http://data.bioontology.org/ontologies/MO/submissions/2>) FILTER(?attributeProperty = <http://data.bioontology.org/metadata/submissionId> ||
?attributeProperty = <http://data.bioontology.org/metadata/prefLabelProperty> || ?attributeProperty = <http://data.bioontology.org/metadata/definitionProperty> ||
?attributeProperty = <http://data.bioontology.org/metadata/synonymProperty> || ?attributeProperty = <http://data.bioontology.org/metadata/authorProperty> ||
?attributeProperty = <http://data.bioontology.org/metadata/classType> || ?attributeProperty = <http://data.bioontology.org/metadata/hierarchyProperty> ||
?attributeProperty = <http://data.bioontology.org/metadata/obsoleteProperty> || ?attributeProperty = <http://data.bioontology.org/metadata/obsoleteParent> ||
?attributeProperty = <http://data.bioontology.org/metadata/homepage> || ?attributeProperty = <http://data.bioontology.org/metadata/publication> ||
?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#uri> || ?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#naturalLanguage> ||
?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#documentation> || ?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#version> ||
?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#creationDate> || ?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#description> ||
?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#status> || ?attributeProperty = <http://data.bioontology.org/metadata/released> ||
?attributeProperty = <http://data.bioontology.org/metadata/uploadFilePath> || ?attributeProperty = <http://data.bioontology.org/metadata/diffFilePath> ||
?attributeProperty = <http://data.bioontology.org/metadata/masterFileName> || ?attributeProperty = <http://data.bioontology.org/metadata/missingImports> ||
?attributeProperty = <http://data.bioontology.org/metadata/pullLocation> || ?attributeProperty = <http://data.bioontology.org/metadata/metrics> ||
?attributeProperty = <http://data.bioontology.org/metadata/contact> || ?attributeProperty = <http://omv.ontoware.org/2005/05/ontology#hasOntologyLanguage> ||
?attributeProperty = <http://data.bioontology.org/metadata/ontology> || ?attributeProperty = <http://data.bioontology.org/metadata/submissionStatus>) }

  And new query with inverse attributes:
SELECT DISTINCT ?id ?attributeProperty ?attributeObject ?inverseAttributeObject
FROM <http://data.bioontology.org/metadata/Ontology> FROM <http://data.bioontology.org/metadata/OntologySubmission>
WHERE { ?id a <http://data.bioontology.org/metadata/Ontology> . OPTIONAL { ?id ?attributeProperty ?attributeObject . } OPTIONAL { ?inverseAttributeObject ?attributeProperty ?id . }
FILTER(?id = <http://data.bioontology.org/ontologies/MO>) FILTER(?attributeProperty = <http://data.bioontology.org/metadata/ontology>) }

=end


      ########
      # TODO: the building of all SPARQL queries that are used by GOO to retrieve objects from the triplestore are done here
      # How the query was built was really bad to get list of attributes. This have been improved by changing how it is built
      # Now it is returning a result for each attribute we want to retrieve constructing the query with :attributeProperty, :attributeObject
      # instead of listing every attributes in the variable we want to retrieve.
      # This new way is not totally optimized. But it works to get ontologies, users, submissions, search
      # But running the ontologies_linked_data tests shows 6 errors to fix
      # One error is linked to aggregate/childrenCount. It seems to be used for "search" but I couldn't find when it is really used in practice
      # To enhance and push those changes in production we need to pass all tests and better understand every cases of query building to be sure
      # the query building is optimized and stable
      # The GOO tests are not actually working, run ontologies_linked_data tests to test this
      ########
      def self.model_load_sliced(*options)
        options = options.last
        ids = options[:ids]
        klass = options[:klass]
        incl = options[:include]
        models = options[:models]
        query_filters = options[:filters]
        # TODO: aggregate is only used by childrenCount in Class. That is used by get_index_doc (used only for search,
        # and I didn't managed to trigger it using the ontologies_api) so I wonder if it is really used
        aggregate = options[:aggregate]
        read_only = options[:read_only]
        graph_match = options[:graph_match]
        enable_rules = options[:rules]
        order_by = options[:order_by]
        collection = options[:collection]
        page = options[:page]
        model_query_options = options[:query_options]
        count = options[:count]
        include_pagination = options[:include_pagination]
        equivalent_predicates = options[:equivalent_predicates]
        predicates = options[:predicates]
        predicates_map = nil
        binding_as = nil
        if predicates
          uniq_p = predicates.uniq
          predicates_map = {}
          uniq_p.each do |p|
            i = 0
            key = ("var_"+p.last_part+i.to_s).to_sym
            while predicates_map.include?(key)
              i += 1
              key = ("var_"+p.last_part+i.to_s).to_sym
              break if i > 10
            end
            predicates_map[key] = p
          end
        end
        store = options[:store] || :main
        klass_struct = nil
        embed_struct = nil

        if read_only && !count && !aggregate
          include_for_struct = incl
          if !incl and include_pagination
            #read only and pagination we do not know the attributes yet
            include_for_struct = include_pagination
          end
          direct_incl = !include_for_struct ? [] :
            include_for_struct.select { |a| a.instance_of?(Symbol) }
          incl_embed = include_for_struct.select { |a| a.instance_of?(Hash) }.first
          klass_struct = klass.struct_object(direct_incl + (incl_embed ? incl_embed.keys : []))

          embed_struct = {}
          if incl_embed
            incl_embed.each do |k,vals|
              next if klass.collection?(k)
              attrs_struct = []
              vals.each do |v|
                attrs_struct << v unless v.kind_of?(Hash)
                attrs_struct.concat(v.keys) if v.kind_of?(Hash)
              end
              embed_struct[k] = klass.range(k).struct_object(attrs_struct)
            end
          end
          direct_incl.each do |attr|
            next if embed_struct.include?(attr)
            embed_struct[attr] = klass.range(attr).struct_object([]) if klass.range(attr)
          end

        end

        if models
          models.each do |m|
            if not m.nil? and !m.respond_to?:klass #read only
              raise ArgumentError,
              "To load attributes the resource must be persistent" unless m.persistent?
            end
          end
        end

        graphs = [klass.uri_type(collection)]
        if collection
          if collection.is_a?Array and collection.length > 0
            graphs = collection.map { |x| x.id }
          elsif !collection.is_a?Array
            graphs = [collection.id]
          end
        end
        models_by_id = {}
        if models
          ids = []
          models.each do |m|
            ids << m.id
            models_by_id[m.id] = m
          end
        elsif ids
          ids.each do |id|
            models_by_id[id] = klass_struct ? klass_struct.new : klass.new
            models_by_id[id].klass = klass if klass_struct
            models_by_id[id].id = id
          end
        else #a where without models

        end

        variables = [:id]

        ## Generate the query
        query_options = {}
        #TODO: breaks the reasoner
        patterns = [[ :id ,RDF.type, klass.uri_type(collection)]]
        unions = []
        optional_patterns = []
        graph_items_collection = nil
        inverse_klass_collection = nil
        incl_embed = nil
        unmapped = nil
        bnode_extraction = nil
        if incl
          # In case there are "include" properties
          if incl.first and incl.first.is_a?(Hash) and incl.first.include?:bnode
            # To include blank node (doesn't seems to be really used...)
            #limitation only one level BNODE
            bnode_conf = incl.first[:bnode]
            klass_attr = bnode_conf.keys.first
            bnode_extraction=klass_attr
            bnode = RDF::Node.new
            patterns << [:id, klass.attribute_uri(klass_attr,collection), bnode]
            bnode_conf[klass_attr].each do |in_bnode_attr|
              variables << in_bnode_attr
              patterns << [bnode, klass.attribute_uri(in_bnode_attr,collection), in_bnode_attr]
            end
          elsif incl.first == :unmapped
            # To get attribute that have not been mapped to the object (to get all class properties for example!)
            # https://github.com/ncbo/goo#working-with-unknown-attributes---schemaless-objects
            #a filter with for ?predicate will be included
            if predicates_map
              variables = [:id, :object, :bind_as]
              binding_as = []
              predicates_map.each do |var,pre|
                binding_as << [[[:id, pre, :object]], var, :bind_as]
              end
            else
              patterns << [:id, :predicate, :object]
              variables = [:id, :predicate, :object]
            end
            unmapped = true
          else
            # "includes are generated here!"
            #make it deterministic
            incl = incl.to_a
            incl_direct = incl.select { |a| a.instance_of?(Symbol) }
            #variables.concat(incl_direct)
            incl_embed = incl.select { |a| a.instance_of?(Hash) }
            raise ArgumentError, "Not supported case for embed" if incl_embed.length > 1
            incl.delete_if { |a| !a.instance_of?(Symbol) }

            if incl_embed.length > 0
              # just get keys for embedded variables to add it to the included properties to retrieve
              incl_embed = incl_embed.first
              embed_variables = incl_embed.keys.sort
              #variables.concat(embed_variables)
              incl.concat(embed_variables)
            end
            variables.concat([:attributeProperty, :attributeObject])
            # TODO: est-ce vraiment nécessaire d'utiliser optional ici ?
            optional_patterns = [[:id, :attributeProperty, :attributeObject]]
            array_includes_filter = []
            uri_properties_hash = {}  # hash that contains "URI of the property => attribute label"
            inversed = false
            incl.each do |attr|
              graph, pattern = query_pattern(klass,attr,collection: collection)
              # pattern is an array of this form: [:id, #<RDF::URI:0x3fc384d47ad8(http://data.bioontology.org/metadata/firstName)>, :firstName]
              add_rules(attr,klass,query_options)
              # TODO: improve how the inverse attributes are retrieved?
              if klass.attributes(:all).include?(attr) && klass.inverse?(attr) && inversed == false
                # In case we have an inverse attribute to retrieve (i.e.: submissions linked to an ontology)
                inversed = true
                variables.concat([:inverseAttributeObject])
                optional_patterns << [:inverseAttributeObject, :attributeProperty, :id]
              end
              # When doing a "bring" the poorly written optional patterns come from here
              #optional_patterns << pattern if pattern
              array_includes_filter << pattern[1] # just take the URI of the attribute property

              # The URI of the property is added to an hash (i.e.: "http://data.bioontology.org/metadata/def/prefLabel" => "prefLabel")
              # so we can retrieve the property linked to this URI when retrieving the results
              uri_properties_hash[pattern[1]] = attr
              graphs << graph if graph && (!klass.collection_opts || klass.inverse?(attr))
            end

            array_includes_filter, uri_properties_hash = expand_equivalent_predicates_filter(equivalent_predicates, array_includes_filter, uri_properties_hash)
            array_includes_filter.uniq!
          end
        end

        internal_variables = []
        if graph_match
          #make it deterministic - for caching
          graph_match_iteration = Goo::Base::PatternIteration.new(graph_match)
          walk_pattern(klass,graph_match_iteration,graphs,patterns,unions,
                             internal_variables,in_aggregate=false,query_options,collection)
          graphs.uniq!
        end

        filter_id = []
        if ids
          ids.each do |id|
            filter_id << "?id = #{id.to_ntriples.to_s}"
          end
        end
        filter_id_str = filter_id.join " || "

        query_filter_str = []
        if query_filters
          filter_patterns = []
          filter_graphs = []
          inspected_patterns = {}
          query_filters.each do |query_filter|
            filter_operations = []
            type = query_filter_sparql(klass,query_filter,filter_patterns,filter_graphs,
                                                filter_operations, internal_variables,
                                                 inspected_patterns,collection)
            query_filter_str << filter_operations.join(" ")
            graphs.concat(filter_graphs) if filter_graphs.length > 0
            if filter_patterns.length > 0
              if type == :optional
                optional_patterns.concat(filter_patterns)
              else
                patterns.concat(filter_patterns)
              end
            end
          end
        end

        aggregate_vars = nil
        aggregate_projections = nil
        if aggregate
          aggregate.each do |agg|
            agg_patterns = []
            graph_match_iteration =
              Goo::Base::PatternIteration.new(Goo::Base::Pattern.new(agg.pattern))
            walk_pattern(klass,graph_match_iteration,graphs,agg_patterns,unions,
                             internal_variables,in_aggregate=agg.aggregate,collection)
            if agg_patterns.length > 0
              projection = "#{internal_variables.last.to_s}_projection".to_sym
              aggregate_on_attr = internal_variables.last.to_s
              aggregate_on_attr =
                aggregate_on_attr[0..aggregate_on_attr.index("_agg_")-1].to_sym
              (aggregate_projections ||={})[projection] = [agg.aggregate, aggregate_on_attr]
              (aggregate_vars ||= []) << [ internal_variables.last,
                                projection,
                               agg.aggregate ]
              variables << projection
              optional_patterns.concat(agg_patterns)
            end
          end
        end
        order_by = nil if count
        if order_by
          order_by = order_by.first
          #simple ordering ... needs to use pattern inspection
          order_by.each do |attr,direction|
            quad = query_pattern(klass,attr)
            patterns << quad[1]
          end
        end

        query_options[:rules]=[:NONE] unless enable_rules
        query_options = nil if query_options.length == 0

        client = Goo.sparql_query_client(store)
        variables = [] if count

        #rdf:type <x> breaks the reasoner
        if query_options && query_options[:rules] != [:NONE]
          patterns[0] = [:id,RDF[:type],:some_type]
          variables << :some_type
        end

        # the select query is constructed here!
        select = client.select(*variables).distinct()
        variables.delete :some_type


        select.where(*patterns)
        optional_patterns.each do |optional|
          select.optional(*[optional])
        end
        select.union(*unions) if unions.length > 0
        if order_by
          order_by_str = order_by.map { |attr,order| "#{order.to_s.upcase}(?#{attr})" }
          select.order_by(*order_by_str)
        end

        select.filter(filter_id_str)

        # Add the included attributes properties to the filter (to retrieve all the attributes we ask for)
        if !array_includes_filter.nil? && array_includes_filter.length > 0
          filter_predicates = array_includes_filter.map { |p| "?attributeProperty = #{p.to_ntriples}" }
          filter_predicates = filter_predicates.join " || "
          select.filter(filter_predicates)
        end

        #if unmapped && predicates && predicates.length > 0
        #  filter_predicates = predicates.map { |p| "?predicate = #{p.to_ntriples}" }
        #  filter_predicates = filter_predicates.join " || "
        #  select.filter(filter_predicates)
        #end

        if query_filter_str.length > 0
          query_filter_str.each do |f|
            select.filter(f)
          end
        end
        if aggregate_vars
          select.options[:group_by]=[:id]
          select.options[:count]=aggregate_vars
        end
        if count
          select.options[:count]=[[:id,:count_var,:count]]
        end
        if page
          offset = (page[:page_i]-1) * page[:page_size]
          select.slice(offset,page[:page_size])
        end
        select.distinct(true)
        if query_options && !binding_as
          query_options[:rules] = query_options[:rules].map { |x| x.to_s }.join("+")
          select.options[:query_options] = query_options
        else
          query_options = { rules: ["NONE"] }
          select.options[:query_options] = query_options
        end

        if not graphs.nil?
          if graphs.length > 0
            graphs.select! { |g| g.to_s["owl#Class"].nil? }
          end
        end

        unless options[:no_graphs]
          select.from(graphs.uniq)
        else
          select.options[:graphs] = graphs.uniq
        end

        query_options.merge!(model_query_options) if model_query_options
        found = Set.new
        list_attributes = Set.new(klass.attributes(:list))
        all_attributes = Set.new(klass.attributes(:all))
        objects_new = {}
        if binding_as
          select.union_with_bind_as(*binding_as)
        end

        # TODO: remove it? expand_equivalent_predicates_filter does the job now
        expand_equivalent_predicates(select,equivalent_predicates)
        var_set_hash = {}
        id_array = []

        puts "#{select}"

        # iterate other solutions of the select query
        select.each_solution do |sol|
          next if sol[:some_type] && klass.type_uri(collection) != sol[:some_type]
          if count
            return sol[:count_var].object
          end
          found.add(sol[:id])
          id = sol[:id]
          id_array << id
          if bnode_extraction
            struct = klass.range(bnode_extraction).new
            variables.each do |v|
              next if v == :id
              svalue = sol[v]
              struct[v] = svalue.is_a?(RDF::Node) ? svalue : svalue.object
            end
            if list_attributes.include?(bnode_extraction)
              pre = models_by_id[sol[:id]].instance_variable_get("@#{bnode_extraction}")
              pre = pre ? (pre.dup << struct) : [struct]
              struct = pre
            end
            models_by_id[sol[:id]].send("#{bnode_extraction}=",struct)
            next
          end
          if !models_by_id.include?(id)
            klass_model = klass_struct ? klass_struct.new : klass.new
            klass_model.id = id
            klass_model.persistent = true unless klass_struct
            klass_model.klass = klass if klass_struct
            models_by_id[id] = klass_model
          end
          if unmapped
            if predicates_map.nil?
              if models_by_id[id].respond_to? :klass #struct
                models_by_id[id][:unmapped] ||= {}
                (models_by_id[id][:unmapped][sol[:predicate]] ||= []) << sol[:object]
              else
                models_by_id[id].unmapped_set(sol[:predicate],sol[:object])
              end
            else
              var = sol[:bind_as].to_s.to_sym
              if predicates_map.include?(var)
                pred = predicates_map[var]
                if models_by_id[id].respond_to?:klass #struct
                  models_by_id[id][:unmapped] ||= {}
                  (models_by_id[id][:unmapped][pred] ||= Set.new) << sol[:object]
                else
                  models_by_id[id].unmapped_set(pred,sol[:object])
                end
              end
            end
            next
          end

          # Retrieve all included attributes
          if !sol[:attributeProperty].nil?

            # Get the property label using the hash
            v = uri_properties_hash[sol[:attributeProperty]]
            if !sol[:attributeObject].nil?
              object = sol[:attributeObject]
            elsif !sol[:inverseAttributeObject].nil?
              object = sol[:inverseAttributeObject]
            else
              object = nil
            end

            if (v != :id) && !all_attributes.include?(v)
              if aggregate_projections && aggregate_projections.include?(v)
                conf = aggregate_projections[v]
                if models_by_id[id].respond_to?:add_aggregate
                models_by_id[id].add_aggregate(conf[1], conf[0], sol[v].object)
                else
                  (models_by_id[id].aggregates ||= []) <<
                      Goo::Base::AGGREGATE_VALUE.new(conf[1], conf[0], sol[v].object)
                end
              end
              #TODO otther schemaless things
              next
            end
            #group for multiple values

            #bnodes
            if object.kind_of?(RDF::Node) && object.anonymous? && incl.include?(v)
              range = klass.range(v)
              if range.respond_to?(:new)
                objects_new[object] = BNODES_TUPLES.new(id,v)
              end
              next
            end

            if object and !(object.kind_of? RDF::URI)
              object = object.object
            end

            #dependent model creation
            if object.kind_of?(RDF::URI) && v != :id
              range_for_v = klass.range(v)
              if range_for_v
                if objects_new.include?(object)
                  object = objects_new[object]
                else
                  unless range_for_v.inmutable?
                    pre_val = nil
                    if models_by_id[id] &&
                        ((models_by_id[id].respond_to?(:klass) && models_by_id[id]) ||
                            models_by_id[id].loaded_attributes.include?(v))
                      if !read_only
                        pre_val = models_by_id[id].instance_variable_get("@#{v}")
                      else
                        pre_val = models_by_id[id][v]
                      end
                      if pre_val.is_a?(Array)
                        pre_val = pre_val.select { |x| x.id == object }.first
                      end
                    end
                    if !read_only
                      object = pre_val ? pre_val : klass.range_object(v,object)
                      objects_new[object.id] = object
                    else
                      #depedent read only
                      struct = pre_val ? pre_val : embed_struct[v].new
                      struct.id = object
                      struct.klass = klass.range(v)
                      objects_new[struct.id] = struct
                      object = struct
                    end
                  else
                    object = range_for_v.find(object).first
                  end
                end
              end
            end

            if list_attributes.include?(v)
              # To handle attr that are lists
              pre = klass_struct ? models_by_id[id][v] :
                  models_by_id[id].instance_variable_get("@#{v}")
              if object.nil? && pre.nil?
                object = []
              elsif object.nil? && !pre.nil?
                object = pre
              elsif object
                object = !pre ? [object] : (pre.dup << object)
                object.uniq!
              end
            end
            if models_by_id[id].respond_to?(:klass)
              unless object.nil? && !models_by_id[id][v].nil?
                models_by_id[id][v] = object
              end
            else
              unless models_by_id[id].class.handler?(v)
                unless object.nil? && !models_by_id[id].instance_variable_get("@#{v.to_s}").nil?
                  if v != :id
                    # if multiple language values are included for a given property, set the
                    # corresponding model attribute to the English language value - NCBO-1662
                    if sol[v].kind_of?(RDF::Literal)
                      key = "#{v}#__#{id.to_s}"
                      models_by_id[id].send("#{v}=", object, on_load: true) unless var_set_hash[key]
                      lang = sol[v].language
                      var_set_hash[key] = true if lang == :EN || lang == :en
                    else
                      models_by_id[id].send("#{v}=", object, on_load: true)
                    end
                  end
                end
              end
            end
          end

=begin
          variables.each do |v|
            next if v == :id and models_by_id.include?(id)
            if (v != :id) && !all_attributes.include?(v)
              if aggregate_projections && aggregate_projections.include?(v)
                conf = aggregate_projections[v]
                if models_by_id[id].respond_to?:add_aggregate
                  models_by_id[id].add_aggregate(conf[1], conf[0], sol[v].object)
                else
                  (models_by_id[id].aggregates ||= []) <<
                   Goo::Base::AGGREGATE_VALUE.new(conf[1], conf[0], sol[v].object)
                end
              end
              #TODO otther schemaless things
              next
            end
            #group for multiple values
            object = sol[v] ? sol[v] : nil

            #bnodes
            if object.kind_of?(RDF::Node) && object.anonymous? && incl.include?(v)
              range = klass.range(v)
              if range.respond_to?(:new)
                objects_new[object] = BNODES_TUPLES.new(id,v)
              end
              next
            end

            if object and !(object.kind_of? RDF::URI)
              object = object.object
            end

            #dependent model creation
            if object.kind_of?(RDF::URI) && v != :id
              range_for_v = klass.range(v)
              if range_for_v
                if objects_new.include?(object)
                  object = objects_new[object]
                else
                  unless range_for_v.inmutable?
                    pre_val = nil
                    if models_by_id[id] &&
                       ((models_by_id[id].respond_to?(:klass) && models_by_id[id]) ||
                       models_by_id[id].loaded_attributes.include?(v))
                       if !read_only
                         pre_val = models_by_id[id].instance_variable_get("@#{v}")
                       else
                         pre_val = models_by_id[id][v]
                       end
                       if pre_val.is_a?(Array)
                         pre_val = pre_val.select { |x| x.id == object }.first
                       end
                    end
                    if !read_only
                      object = pre_val ? pre_val : klass.range_object(v,object)
                      objects_new[object.id] = object
                    else
                      #depedent read only
                      struct = pre_val ? pre_val : embed_struct[v].new
                      struct.id = object
                      struct.klass = klass.range(v)
                      objects_new[struct.id] = struct
                      object = struct
                    end
                  else
                    object = range_for_v.find(object).first
                  end
                end
              end
            end

            if list_attributes.include?(v)
              pre = klass_struct ? models_by_id[id][v] :
                                   models_by_id[id].instance_variable_get("@#{v}")
              if object.nil? && pre.nil?
                object = []
              elsif object.nil? && !pre.nil?
                object = pre
              elsif object
                object = !pre ? [object] : (pre.dup << object)
                object.uniq!
              end
            end
            if models_by_id[id].respond_to?(:klass)
              unless object.nil? && !models_by_id[id][v].nil?
                models_by_id[id][v] = object
              end
            else
              unless models_by_id[id].class.handler?(v)
                unless object.nil? && !models_by_id[id].instance_variable_get("@#{v.to_s}").nil?
                  if v != :id
                    # if multiple language values are included for a given property, set the
                    # corresponding model attribute to the English language value - NCBO-1662
                    if sol[v].kind_of?(RDF::Literal)
                      key = "#{v}#__#{id.to_s}"
                      models_by_id[id].send("#{v}=", object, on_load: true) unless var_set_hash[key]
                      lang = sol[v].language
                      var_set_hash[key] = true if lang == :EN || lang == :en
                    else
                      models_by_id[id].send("#{v}=", object, on_load: true)
                    end
                  end
                end
              end
            end
          end
=end

        end

        if !incl.nil?
          # Here we are setting to nil all attributes that have been included but not found in the triplestore
          id_array.uniq!
          incl.each do |attr_to_incl|
            # Go through all attr we had to include
            id_array.each do |model_id|
              # Go through all models queried
              if models_by_id[model_id].respond_to?("loaded_attributes") && !models_by_id[model_id].loaded_attributes.include?(attr_to_incl) && models_by_id[model_id].respond_to?(attr_to_incl) && !attr_to_incl.to_s.eql?("unmapped")
                if list_attributes.include?(attr_to_incl)
                  # If the asked attr has not been loaded then it is set to nil or to an empty array for list attr
                  models_by_id[model_id].send("#{attr_to_incl}=", [], on_load: true)
                else
                  models_by_id[model_id].send("#{attr_to_incl}=", nil, on_load: true)
                end
              end
            end
          end
        end

        return models_by_id if bnode_extraction

        collection_value = nil
        if klass.collection_opts.instance_of?(Symbol)
          if collection.is_a?Array and collection.length == 1
            collection_value = collection.first
          end
          if collection.respond_to?:id
            collection_value = collection
          end
        end
        if collection_value
          collection_attribute = klass.collection_opts
          models_by_id.each do |id,m|
            m.send("#{collection_attribute}=", collection_value)
          end
          objects_new.each do |id,obj_new|
            if obj_new.respond_to?(:klass)
              collection_attribute = obj_new[:klass].collection_opts
              obj_new[collection_attribute] = collection_value
            elsif obj_new.class.respond_to?(:collection_opts) &&
                obj_new.class.collection_opts.instance_of?(Symbol)
              collection_attribute = obj_new.class.collection_opts
              obj_new.send("#{collection_attribute}=", collection_value)
            end
          end
        end

        #remove from models_by_id elements that were not touched
        models_by_id.select! { |k,m| found.include?(k) }

        unless read_only
          if options[:ids] #newly loaded
            models_by_id.each do |k,m|
              m.persistent=true
            end
          end
        end

        #next level of embed attributes
        if incl_embed && incl_embed.length > 0
          incl_embed.each do |attr,next_attrs|
            #anything to join ?
            attr_range = klass.range(attr)
            next if attr_range.nil?
            range_objs = objects_new.select { |id,obj| obj.instance_of?(attr_range) ||
                                      (obj.respond_to?(:klass) && obj[:klass] == attr_range)
                                            }.values
            if range_objs.length > 0
              range_objs.uniq!
              attr_range.where().models(range_objs).in(collection).include(*next_attrs).all
            end
          end
        end

        #bnodes
        bnodes = objects_new.select { |id,obj| id.is_a?(RDF::Node) && id.anonymous? }
        if bnodes.length > 0
          #group by attribute
          attrs = bnodes.map { |x,y| y.attribute }.uniq
          attrs.each do |attr|
            struct = klass.range(attr)

            #bnodes that are in a range of goo ground models
            #for example parents and children in LD class models
            #we skip this cases for the moment
            next if struct.respond_to?(:model_name)

            bnode_attrs = struct.new.to_h.keys
            ids = bnodes.select { |x,y| y.attribute == attr }.map{ |x,y| y.id }
            klass.where.models(models_by_id.select { |x,y| ids.include?(x) }.values)
                          .in(collection)
                          .include(bnode: { attr => bnode_attrs}).all
          end
        end
        if unmapped
          models_by_id.each do |idm,m|
            m.unmmaped_to_array
          end
        end

        return models_by_id
      end

    end #queries
  end #SPARQL
end #Goo
