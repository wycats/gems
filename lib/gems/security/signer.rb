##
# Basic OpenSSL-based package signing class.

class Gems::Security::Signer

  attr_accessor :cert_chain
  attr_accessor :key
  attr_reader :digest_algorithm

  ##
  # Creates a new signer with an RSA +key+ or path to a key, and a certificate
  # +chain+ containing X509 certificates, encoding certificates or paths to
  # certificates.

  def initialize key, cert_chain
    @cert_chain = cert_chain
    @key        = key

    unless @key then
      default_key  = File.join Gem.user_home, 'gem-private_key.pem'
      @key = default_key if File.exist? default_key
    end

    unless @cert_chain then
      default_cert = File.join Gem.user_home, 'gem-public_cert.pem'
      @cert_chain = [default_cert] if File.exist? default_cert
    end

    @digest_algorithm = Gems::Security::DIGEST_ALGORITHM

    @key = OpenSSL::PKey::RSA.new File.read @key if
      @key and not OpenSSL::PKey::RSA === @key

    if @cert_chain then
      @cert_chain = @cert_chain.compact.map do |cert|
        next cert if OpenSSL::X509::Certificate === cert

        cert = File.read cert if File.exist? cert

        OpenSSL::X509::Certificate.new cert
      end

      load_cert_chain
    end
  end

  ##
  # Loads any missing issuers in the cert chain from the trusted certificates.
  #
  # If the issuer does not exist it is ignored as it will be checked later.

  def load_cert_chain # :nodoc:
    return if @cert_chain.empty?

    while @cert_chain.first.issuer.to_s != @cert_chain.first.subject.to_s do
      issuer = Gems::Security.trust_dir.issuer_of @cert_chain.first

      break unless issuer # cert chain is verified later

      @cert_chain.unshift issuer
    end
  end

  ##
  # Sign data with given digest algorithm

  def sign data
    return unless @key

    if @cert_chain.length == 1 and @cert_chain.last.not_after < Time.now then
      re_sign_key
    end

    Gems::Security::SigningPolicy.verify @cert_chain, @key

    @key.sign @digest_algorithm.new, data
  end

  ##
  # Attempts to re-sign the private key if the signing certificate is expired.
  #
  # The key will be re-signed if:
  # * The expired certificate is self-signed
  # * The expired certificate is saved at ~/.gem/gem-public_cert.pem
  # * There is no file matching the expiry date at
  #   ~/.gem/gem-public_cert.pem.expired.%Y%m%d%H%M%S
  #
  # If the signing certificate can be re-signed the expired certificate will
  # be saved as ~/.gem/gem-pubilc_cert.pem.expired.%Y%m%d%H%M%S where the
  # expiry time (not after) is used for the timestamp.

  def re_sign_key # :nodoc:
    old_cert = @cert_chain.last

    disk_cert_path = File.join Gem.user_home, 'gem-public_cert.pem'
    disk_cert = File.read disk_cert_path rescue nil
    disk_key  =
      File.read File.join(Gem.user_home, 'gem-private_key.pem') rescue nil

    if disk_key == @key.to_pem and disk_cert == old_cert.to_pem then
      expiry = old_cert.not_after.strftime '%Y%m%d%H%M%S'
      old_cert_file = "gem-public_cert.pem.expired.#{expiry}"
      old_cert_path = File.join Gem.user_home, old_cert_file

      unless File.exist? old_cert_path then
        Gems::Security.write old_cert, old_cert_path

        cert = Gems::Security.re_sign old_cert, @key

        Gems::Security.write cert, disk_cert_path

        @cert_chain = [cert]
      end
    end
  end

end

