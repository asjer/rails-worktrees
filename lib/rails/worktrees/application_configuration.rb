module Rails
  module Worktrees
    # Copies explicit app configuration values onto the runtime configuration object.
    module ApplicationConfiguration
      module_function

      def apply(source, configuration:)
        return configuration unless source

        Configuration::CONFIGURABLE_ATTRIBUTES.each do |attribute|
          next unless assigned?(source, attribute)

          configuration.public_send("#{attribute}=", value_for(source, attribute))
        end

        configuration
      end

      def assigned?(source, attribute)
        key = attribute.to_sym
        hash = source.is_a?(Hash) ? source : source.to_h if source.respond_to?(:to_h)
        return hash.key?(key) || hash.key?(attribute.to_s) if hash

        source.respond_to?(:key?) && (source.key?(key) || source.key?(attribute.to_s))
      end

      def value_for(source, attribute)
        key = attribute.to_sym
        hash = source.is_a?(Hash) ? source : source.to_h if source.respond_to?(:to_h)
        return hash.fetch(key) { hash[attribute.to_s] } if hash

        source.public_send(attribute)
      end
    end
  end
end
