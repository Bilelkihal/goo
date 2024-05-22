require_relative '../test_case'
require 'benchmark'


class TestSolr < MiniTest::Unit::TestCase
  def self.before_suite
    @@connector = SOLR::SolrConnector.new(Goo.search_conf, 'test')
    @@connector.delete_collection('test')
    @@connector.init
  end

  def self.after_suite
    @@connector.delete_collection('test')
  end

  def test_add_collection
    connector = @@connector
    connector.create_collection('test2')
    all_collections = connector.fetch_all_collections
    assert_includes all_collections, 'test2'
  end

  def test_delete_collection
    connector = @@connector
    test_add_collection
    connector.delete_collection('test2')

    all_collections = connector.fetch_all_collections
    refute_includes all_collections, 'test2'
  end

  def test_schema_generator
    connector = @@connector

    all_fields = connector.all_fields

    connector.schema_generator.fields_to_add.each do |f|
      field = all_fields.select { |x| x["name"].eql?(f[:name]) }.first
      refute_nil field
      assert_equal field["type"], f[:type]
      assert_equal field["indexed"], f[:indexed]
      assert_equal field["stored"], f[:stored]
      assert_equal field["multiValued"], f[:multiValued]
    end

    copy_fields = connector.all_copy_fields
    connector.schema_generator.copy_fields_to_add.each do |f|
      field = copy_fields.select { |x| x["source"].eql?(f[:source]) }.first
      refute_nil field
      assert_equal field["source"], f[:source]
      assert_includes f[:dest], field["dest"]
    end

    dynamic_fields = connector.all_dynamic_fields

    connector.schema_generator.dynamic_fields_to_add.each do |f|
      field = dynamic_fields.select { |x| x["name"].eql?(f[:name]) }.first
      refute_nil field
      assert_equal field["name"], f[:name]
      assert_equal field["type"], f[:type]
      assert_equal field["multiValued"], f[:multiValued]
      assert_equal field["stored"], f[:stored]
    end

    connector.clear_all_schema
    connector.fetch_schema
    all_fields = connector.all_fields
    connector.schema_generator.fields_to_add.each do |f|
      field = all_fields.select { |x| x["name"].eql?(f[:name]) }.first
      assert_nil field
    end

    copy_fields = connector.all_copy_fields
    connector.schema_generator.copy_fields_to_add.each do |f|
      field = copy_fields.select { |x| x["source"].eql?(f[:source]) }.first
      assert_nil field
    end

    dynamic_fields = connector.all_dynamic_fields
    connector.schema_generator.dynamic_fields_to_add.each do |f|
      field = dynamic_fields.select { |x| x["name"].eql?(f[:name]) }.first
      assert_nil field
    end
  end

  def test_add_field
    connector = @@connector
    add_field('test', connector)


    field = connector.fetch_all_fields.select { |f| f['name'] == 'test' }.first

    refute_nil field
    assert_equal field['type'], 'string'
    assert_equal field['indexed'], true
    assert_equal field['stored'], true
    assert_equal field['multiValued'], true

    connector.delete_field('test')
  end

  def test_delete_field
    connector = @@connector

    add_field('test', connector)

    connector.delete_field('test')

    field = connector.all_fields.select { |f| f['name'] == 'test' }.first

    assert_nil field
  end

  private

  def add_field(name, connector)
    if connector.fetch_field(name)
      connector.delete_field(name)
    end
    connector.add_field(name, 'string', indexed: true, stored: true, multi_valued: true)
  end
end
