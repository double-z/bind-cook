# Encoding: utf-8
#
# Author:: Jesse Nelson <spheromak@gmail.com>
# Cookbook:: Bind
# Recipe:: server
#
# Build a bind server from bags and other goodness
#

include_recipe 'bind::default'
include_recipe 'bind::common'

Helpers::Dns.node = node

bind_conf 'server' do
  zones node[:dns][:zones]
end

#
# gonna collect all rndc_keys here
keys = node[:dns][:keys] || {}
resource = {}
delegates = {}
node[:dns][:zones].each do |zone|

  zone_data = Helpers::Dns.fetch_zone zone

  if Helpers::Dns.zone_master? zone_data
    type = 'master'
    dhcp_allow = Helpers::Dns.find_dhcp_servers
  else
    type = 'slave'
  end

  log "Setting up DNS Zone: #{zone}"

  # make sure we have all the data we need
  Helpers::Dns.validate_zone_data(type, zone_data)

  # clobber merge keys
  if zone_data.key?('keys')
    keys = Chef::Mixin::DeepMerge.merge(keys, zone_data['keys'])
  end

  # crate the zone record
  bind_zone zone do
    zone_type type
    zone_data zone_data
    allow_query 'any'
    allow_update dhcp_allow
  end

  #
  # Create the Base Zone File
  # this should only be created ever once
  # after that its all dynamic updates
  #
  template "/var/named/#{type}/db/#{zone}" do
    action :create_if_missing
    source 'db.erb'
    owner node[:bind][:user]
    group node[:bind][:group]
    mode  0640
    variables(name: zone, data: zone_data)
    notifies :restart, "service[#{node[:bind][:service_name]}]"
  end


  #
  #
  # setup the nsupdate exec for this zone
  # resources below will exec it
  #
  execute "nsupdate_#{zone}" do
    action :nothing
    #
    # due to a bug in nsupdate it will always assert even when it succeds
    # we need to grep and us returns 1  to ensure our grep oens't match (fail condition)
    # nsupdate bug: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=622084
    # command "nsupdate -v /var/named/#{type}/rr/#{zone}  2>&1 | grep 'update failed:' "
    # returns 1
    opts = ''
    case node[:platform_family]
    when 'rhel'
      opts = '-v'
    when 'debian'
      opts = '-lv'
    end

    command "nsupdate #{opts} /var/named/#{type}/rr/#{zone}"
  end

  # collect txt record info from searchs on this domain
  # parse the resource_records in this zone and get the formated entries
  #  for now disable txt records so dhcp can update
  # resources = build_resources(collect_txt(bag["resource_records"]), bag["zone_name"])
  resources = Helpers::Dns.build_resources(zone_data['resource_records'], zone_data['zone_name'])

  # build delegate list
  delegates =  Helpers::Dns.load_delegates(zone_data)

  # generate nsupdate file
  template "/var/named/#{type}/rr/#{zone}" do
    source 'nsupdate.erb'
    owner node[:bind][:user]
    group node[:bind][:group]
    mode  0640
    variables(
      zone: zone_data['zone_name'],
      records: resources,
      # set the ttl for delegates
      ttl: '172800',
      delegates: delegates
    )
    notifies :run, "execute[nsupdate_#{zone}]", :delayed
  end
end

# build out rndc
node.run_state[:dns_keys] = keys
include_recipe 'bind::_keys'
