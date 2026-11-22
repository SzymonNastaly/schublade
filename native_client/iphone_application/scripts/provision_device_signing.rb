# Provisions the iPhone application for the devices registered to the team, through the App Store
# Connect API, and writes configuration/local_signing.xcconfig to sign with what it provisioned.
#   ruby native_client/iphone_application/scripts/provision_device_signing.rb
#
# Runs in the Mac's build account, which holds the Apple Development identity and the team key in
# ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_PATH. Xcode's automatic signing refuses a key below
# the Admin role, and the API cannot create an App Group, so the owner creates
# group.org.schublade.iphone and assigns it to the application and the share extension in the
# developer portal once. Running it again replaces the profiles, so a newly registered device or an
# expired profile needs nothing else. It provisions the Release identifiers only: a Debug build runs
# on the simulator, which needs no profile.
require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"

TEAM_IDENTIFIER = "R69J54A3P5"
APPLICATION_GROUP = "group.org.schublade.iphone"
TARGETS = [
  { bundle: "org.schublade.iphone", name: "Schublade", group: true, setting: "APPLICATION_PROVISIONING_PROFILE" },
  { bundle: "org.schublade.iphone.share-extension", name: "Schublade share extension", group: true,
    setting: "SHARE_EXTENSION_PROVISIONING_PROFILE" },
  { bundle: "org.schublade.iphone.controls", name: "Schublade controls", group: false,
    setting: "CONTROL_EXTENSION_PROVISIONING_PROFILE" },
].freeze
PROFILE_DIRECTORIES = [
  File.expand_path("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
  File.expand_path("~/Library/MobileDevice/Provisioning Profiles"),
].freeze

def base64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

# A token of ten minutes, signed with ES256 as the API requires: the signature is the raw pair of
# 32-byte integers, not the DER sequence OpenSSL returns.
def bearer_token
  key = OpenSSL::PKey::EC.new(File.read(ENV.fetch("ASC_PRIVATE_KEY_PATH")))
  now = Time.now.to_i
  header = { alg: "ES256", kid: ENV.fetch("ASC_KEY_ID"), typ: "JWT" }
  claims = { iss: ENV.fetch("ASC_ISSUER_ID"), iat: now, exp: now + 600, aud: "appstoreconnect-v1" }
  signed = "#{base64url(header.to_json)}.#{base64url(claims.to_json)}"
  signature = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest.new("SHA256"), signed))
  "#{signed}.#{base64url(signature.value.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join)}"
end

def request(method, path, body = nil)
  uri = URI("https://api.appstoreconnect.apple.com#{path}")
  message = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
  message["Authorization"] = "Bearer #{bearer_token}"
  if body
    message["Content-Type"] = "application/json"
    message.body = body.to_json
  end
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(message) }
  abort "#{method.upcase} #{path} answered #{response.code}: #{response.body}" unless response.code.start_with?("2")
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end

def query(path, parameters)
  "#{path}?#{URI.encode_www_form(parameters)}"
end

# The registered identifier of `target`, registered with the App Groups capability when absent.
def bundle_identifier(target)
  found = request(:get, query("/v1/bundleIds", "filter[identifier]" => target[:bundle]))["data"]
    .find { |record| record["attributes"]["identifier"] == target[:bundle] }
  return found["id"] if found

  created = request(:post, "/v1/bundleIds", data: {
    type: "bundleIds",
    attributes: { identifier: target[:bundle], name: target[:name], platform: "IOS" },
  })["data"]["id"]
  if target[:group]
    request(:post, "/v1/bundleIdCapabilities", data: {
      type: "bundleIdCapabilities",
      attributes: { capabilityType: "APP_GROUPS" },
      relationships: { bundleId: { data: { type: "bundleIds", id: created } } },
    })
  end
  created
end

# The development certificate whose private key this account's keychain holds.
def development_certificate
  pem = `security find-certificate -c "Apple Development:" -p`
  abort "The keychain holds no Apple Development certificate." if pem.empty?
  serial = OpenSSL::X509::Certificate.new(pem).serial.to_s(16).upcase
  found = request(:get, query("/v1/certificates", "filter[certificateType]" => "DEVELOPMENT", "limit" => "200"))["data"]
    .find { |record| record["attributes"]["serialNumber"].upcase.sub(/\A0+/, "") == serial.sub(/\A0+/, "") }
  abort "The keychain's Apple Development certificate #{serial} is not the team's." unless found
  found["id"]
end

def iphone_devices
  devices = request(:get, query("/v1/devices", "filter[platform]" => "IOS", "filter[status]" => "ENABLED", "limit" => "200"))["data"]
    .select { |record| record["attributes"]["deviceClass"] == "IPHONE" }
  abort "The team has no iPhone registered." if devices.empty?
  devices
end

# The value at `key` of a profile's signed property list, in plutil's `format`: json for a
# dictionary, raw for a string, because plutil writes no JSON for a bare string.
def profile_value(content, key, format)
  decoded = IO.popen(%w[security cms -D], "r+") do |pipe|
    pipe.write(content)
    pipe.close_write
    pipe.read
  end
  IO.popen(["plutil", "-extract", key, format, "-o", "-", "-"], "r+") do |pipe|
    pipe.write(decoded)
    pipe.close_write
    pipe.read
  end
end

# Xcode finds a profile by its name, so an older file of the same name must not remain beside the new one.
def remove_installed_profiles(name)
  PROFILE_DIRECTORIES.flat_map { |directory| Dir.glob(File.join(directory, "*.mobileprovision")) }.each do |path|
    File.delete(path) if profile_value(File.binread(path), "Name", "raw").chomp == name
  end
end

certificate = development_certificate
devices = iphone_devices
puts "Devices: #{devices.map { |record| record["attributes"]["name"] }.join(", ")}"
settings = TARGETS.map do |target|
  name = "#{target[:name]} development"
  bundle = bundle_identifier(target)
  request(:get, query("/v1/profiles", "filter[name]" => name))["data"].each do |record|
    request(:delete, "/v1/profiles/#{record["id"]}")
  end
  created = request(:post, "/v1/profiles", data: {
    type: "profiles",
    attributes: { name: name, profileType: "IOS_APP_DEVELOPMENT" },
    relationships: {
      bundleId: { data: { type: "bundleIds", id: bundle } },
      certificates: { data: [{ type: "certificates", id: certificate }] },
      devices: { data: devices.map { |record| { type: "devices", id: record["id"] } } },
    },
  })["data"]["attributes"]
  content = Base64.decode64(created["profileContent"])
  groups = Array(JSON.parse(profile_value(content, "Entitlements", "json"))["com.apple.security.application-groups"])
  if target[:group] && !groups.include?(APPLICATION_GROUP)
    abort "#{target[:bundle]} lacks #{APPLICATION_GROUP}. Assign it under Identifiers in the developer portal, then run this again."
  end
  remove_installed_profiles(name)
  PROFILE_DIRECTORIES.each do |directory|
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, "#{created["uuid"]}.mobileprovision"), content)
  end
  puts "#{name}: #{created["uuid"]}, until #{created["expirationDate"]}"
  "#{target[:setting]}[sdk=iphoneos*] = #{name}"
end

File.write(File.expand_path("../configuration/local_signing.xcconfig", __dir__), <<~XCCONFIG)
  // Written by scripts/provision_device_signing.rb. A build for a device signs with the team's Apple
  // Development identity and the profiles it provisioned; the simulator keeps ad hoc signing.
  DEVELOPMENT_TEAM = #{TEAM_IDENTIFIER}
  CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Development
  #{settings.join("\n")}
XCCONFIG
puts "Wrote configuration/local_signing.xcconfig"
