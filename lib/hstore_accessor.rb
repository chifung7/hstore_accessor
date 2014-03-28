require "hstore_accessor/version"
require "active_support"
require "active_record"

module HstoreAccessor
  extend ActiveSupport::Concern

  InvalidDataTypeError = Class.new(StandardError)

  VALID_TYPES = [:string, :integer, :float, :time, :boolean, :array, :hash, :date]

  SEPARATOR = "||;||"

  SERIALIZERS = {
    :array    => -> value { value.join(SEPARATOR) },
    :hash     => -> value { value.to_json },
    :integer  => -> value { value.to_s },
    :float    => -> value { value.to_s },
    :time     => -> value { value.to_i },
    :boolean  => -> value { value.to_s },
    :date     => -> value { value.to_s }
  }

  DESERIALIZERS = {
    :array    => -> value { value.split(SEPARATOR) },
    :hash     => -> value { JSON.parse(value) },
    :integer  => -> value { Integer(value) },
    :float    => -> value { Float(value) },
    :time     => -> value { Time.at(Integer(value)) },
    :boolean  => -> value { value == "true" },
    :date     => -> value { Date.parse(value) }
  }

  def serialize(type, value)
    return nil if value.nil?

    if String === value
      if type == :string or
          # need to parse the string to make sure it is a valid type 
          ((DESERIALIZERS[type].call(value) || true) rescue false)
        value
      else
        nil # not a valid object in string format
      end
    else
      if type == :string
        value.to_s  # or should just raise error
      else
        SERIALIZERS[type].call(value)
      end
    end
  end

  def deserialize(type, value)
    return nil if value.nil?

    if String === value
      if type == :string
        value
      else
        DESERIALIZERS[type].call(value)
      end
    else
      if type == :string
        value.to_s
      else
        value
      end
    end
  end

  module ClassMethods

    def hstore_accessor(hstore_attribute, fields)
      fields.each do |key, type|

        data_type = type
        store_key = key.to_s
        if type.is_a?(Hash)
          type = type.with_indifferent_access
          data_type = type[:data_type]
          store_key = type[:store_key].to_s
        end

        data_type = data_type.to_sym

        raise InvalidDataTypeError unless VALID_TYPES.include?(data_type)

        define_method("hstore_metadata_for_#{hstore_attribute}") do
          fields
        end

        attr_accessor "#{key}_before_type_cast".to_sym

        define_method("#{key}=") do |value|
          send("#{key}_before_type_cast=", value)

          h = send(hstore_attribute) || {}
          v = serialize(data_type, value)

          unless h[store_key].nil? and v.nil?
            send("#{hstore_attribute}=", h.merge(store_key => v))
            send("#{hstore_attribute}_will_change!")
          end
        end

        define_method(key) do
          h = send(hstore_attribute)
          value = h && h.with_indifferent_access[store_key]
          deserialize(data_type, value)
        end

        if type == :boolean
          define_method("#{key}?") do
            return send(key)
          end
        end

        query_field = "#{hstore_attribute} -> '#{store_key}'"
        eq_query_field = "#{hstore_attribute} @> hstore('#{store_key}', ?)"

        case data_type
        when :string
          send(:scope, "with_#{key}", -> value { where(eq_query_field, value.to_s) })
        when :integer, :float
          send(:scope, "#{key}_lt",  -> value { where("(#{query_field})::#{data_type} < ?", value.to_s) })
          send(:scope, "#{key}_lte", -> value { where("(#{query_field})::#{data_type} <= ?", value.to_s) })
          send(:scope, "#{key}_eq",  -> value { where(eq_query_field, value.to_s) })
          send(:scope, "#{key}_gte", -> value { where("(#{query_field})::#{data_type} >= ?", value.to_s) })
          send(:scope, "#{key}_gt",  -> value { where("(#{query_field})::#{data_type} > ?", value.to_s) })
        when :time
          send(:scope, "#{key}_before", -> value { where("(#{query_field})::integer < ?", value.to_i) })
          send(:scope, "#{key}_eq",     -> value { where(eq_query_field, value.to_i.to_s) })
          send(:scope, "#{key}_after",  -> value { where("(#{query_field})::integer > ?", value.to_i) })
        when :date
          send(:scope, "#{key}_before", -> value { where("#{query_field} < ?", value.to_s) })
          send(:scope, "#{key}_eq",     -> value { where(eq_query_field, value.to_s) })
          send(:scope, "#{key}_after",  -> value { where("#{query_field} > ?", value.to_s) })
        when :boolean
          send(:scope, "is_#{key}", -> { where(eq_query_field, 'true') })
          send(:scope, "not_#{key}", -> { where(eq_query_field, 'false') })
        when :array
          send(:scope, "#{key}_eq",        -> value { where(eq_query_field, value.join(SEPARATOR)) })
          send(:scope, "#{key}_contains",  -> value do
            where("string_to_array(#{query_field}, '#{SEPARATOR}') @> string_to_array(?, '#{SEPARATOR}')", Array[value].flatten)
          end)
        end
      end

    end

  end

end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Base.send(:include, HstoreAccessor)
end
