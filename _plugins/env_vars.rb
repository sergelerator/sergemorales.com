module Jekyll
  class EnvironmentVariablesGenerator < Generator
    def generate(site)
      site.config['ga_tracking_code'] = ENV['GA_TRACKING_CODE']
    end
  end
end
