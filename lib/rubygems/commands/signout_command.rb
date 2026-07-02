# frozen_string_literal: true

require_relative "../command"

class Gem::Commands::SignoutCommand < Gem::Command
  def initialize
    super "signout", "Sign out from all the current sessions."
  end

  def description # :nodoc:
    "The `signout` command is used to sign out from all current sessions,"\
    " allowing you to sign in using a different set of credentials. If the"\
    " :credential_store: gemrc option is set, the API key is also removed from"\
    " the credential store it selects."
  end

  def usage # :nodoc:
    program_name
  end

  def execute
    credentials_path = Gem.configuration.credentials_path
    credentials_file_exists = File.exist?(credentials_path)

    if !credentials_file_exists && !Gem.configuration.credential_store_signed_in?
      alert_error "You are not currently signed in."
    elsif credentials_file_exists && !File.writable?(credentials_path)
      alert_error "File '#{Gem.configuration.credentials_path}' is read-only."\
                  " Please make sure it is writable."
    else
      Gem.configuration.unset_api_key!
      say "You have successfully signed out from all sessions."
    end
  end
end
