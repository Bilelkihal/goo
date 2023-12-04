module Goo
  module Validators
    class SuperiorEqualTo < ValidatorBase
      include Validator

      key :superior_equal_to_

      error_message ->(obj) {
        "`#{@attr}` must be superior or equal to `#{@property}`"
      }

      validity_check -> (obj) do
        target_values = self.class.attr_value(@property, @inst)

        return true if target_values.empty?

        return @value >= target_values.first
      end

      def initialize(inst, attr, value, key)
        super(inst, attr, value)
        @property = self.class.property(key)
      end
    end
  end
end
