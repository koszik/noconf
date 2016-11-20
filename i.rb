#!/usr/bin/ruby -w

# https://deveiate.org/code/pg/README_rdoc.html

require 'pp'
require 'pg'
require 'json'


class Switch
    attr_reader :features
    def initialize(switch, sql)
	@switch, @sql = switch, sql
	@features = Sql.conn.exec_params("SELECT switch_features.* FROM switch_features,switches WHERE switch_features.model=switches.model AND switches.id=$1", [switch])
	@features = @features.map { |x| if x == "t"; true elsif x == "f"; false else x; end } # todo ugly hack
    end

    def to_s
	@switch
    end

    def add_module(m)
	prefix, mod, start, last, interface_type = @if.parse(m)
	(start..last).to_a.each { |i| @if.add_interface prefix+mod+i, interface_type[:bw] }
    end

    def interface(interface)
	@if.new(self, interface)
    end
end

class CiscoSwitch < Switch
    def initialize(switch, sql)
        @if = CiscoInterface
        super(switch, sql)
    end
end



def Switch(switch)
    sql = Sql.conn.exec_params("SELECT * FROM switches WHERE id=$1", [switch])[0]
    # if sql.model ...
    CiscoSwitch.new(switch, sql)
end


class Stat
    def self.create(switch, interface)
	puts "echo n | cp -pi /var/atw/rrd/xdl.rrd /var/atw/rrd/#{switch}/#{interface}"
    end

    def self.destroy(switch, interface)
	time = Time.now.to_i
	puts "mv /var/atw/rrd/#{switch}/#{interface} /var/atw/rrd/archive/#{t}-#{switch}-#{interface}; mv /var/atw/rrd/mvtmp/#{switch}_#{interface} /var/atw/rrd/archive/#{t}-#{switch}-mvtmp-#{interface}"
    end
end

# states:
# - unused:
#	physical: shut down
#	logical: doesn't exist yet
# - l2:
#	phy or po usually
# - l3:
#	some ints can only be this type (vl, lo)


# specific must define: expandInterface(interface), 
class Interface
    attr_accessor :switch, :interface
    def initialize(switch, interface)
	@switch = switch
	expand_interface(interface)
	if @interface_range_last == nil
	    begin
	    @if_params = Sql.conn.exec_params("SELECT * FROM if_params WHERE (switch,interface)=($1,$2)", [@switch.to_s, @interface])[0]
	    rescue IndexError
	        @if_params = nil
	    end
	end
    end
    def to_s
	@switch.to_s+"/"+@interface
    end

    def ip(ip)
	Ip.new(self, ip)
    end

    def set(cmd)
	Sql.exec("UPDATE if_params SET #{cmd} WHERE (switch,interface)=($1,$2)", [@switch.to_s, @interface])
    end

    def unfold(list)
	list.gsub(/(\d+)-(\d+)/) {($1..$2).to_a.join(",")}
    end

    def used?
	raise "#{@switch}/#{@interface}: interface not in use" unless @if_params["l2"] == "t" or @if_params["l3"] == "t"
    end

    def unused?
	raise "#{@switch}/#{@interface}: interface already in use" unless @if_params["l2"] == "f" and @if_params["l3"] == "f"
    end

    def is_l2?
	@if_params["l2"] == "t"
    end

    def is_l3?
	raise "#{@switch}/#{@interface}: not in layer3 mode" unless @if_params["l3"] == "t"
    end

    def not_found?
	raise "#{@switch}/#{@interface}: interface already exists" unless @if_params == nil
    end

    def can_l2?
	raise "#{@switch}/#{@interface}: interface not capable for layer2 operation" unless @interface_type[:l2] == true
    end

    def physical?
	raise "#{@switch}/#{@interface}: interface is not physical" unless @interface_type[:physical] == true
    end

    def remove
	used?
    end

    # create interface (insert phys, create logical)
    def create # addmodule, vlan, po
	@interface_range_last ||= @interface_id
	(@interface_id..@interface_range_last).to_a.each { |i|
	    ifname = prefix+mod+i
	    @if.create(intf) ## not nice
	    Sql.exec "INSERT INTO if_params (switch, interface, l2, l3, bandwidth) VALUES($1, $2, false, false, $3)", [@switch.to_s, ifname, @interface_type[:bw]]
	    Stat.create(@switch.to_s, @interface)
	}
    end

    def destroy
	used?
	if is_l3?
	    ips = Sql.conn.exec_params("SELECT family(ip),text(ip) ip,nexthop FROM ip WHERE (l3_switch, l3_interface)=($1, $2)", [@switch.to_s, @interface])
	    if ips != []
		ips.each { |ip|
		    puts "#{ip['family']} #{ip['ip']}"
		    del_ip(ip['family'], ip['ip'])
		}
	    end
	    # remove acl
	end
    end

    def clone(from)
	unused || not_found
	can_l2? if from.is_l2?
	@if.create
	if from.vlan
	    @if.access(from.vlan)
	elsif from.vlan_list
	    @if.trunk(from.vlan_list)
	elsif from.l3
	    @if.layer3
	end
	# mtu bw description acl ...
	mtu(from.mtu) if from.mtu
	bw(from.bw) if from.bw
	ips = Sql.conn.exec_params("SELECT family(ip),text(ip) ip,nexthop FROM ip WHERE (l3_switch, l3_interface)=($1, $2)", [@switch.to_s, @interface])
	if ips != []
	    ips.each { |ip| puts "#{ip['family']} #{ip['ip']}"; add_ip(ip['ip'], ip['nexthop']) }
	end
    end

    def unclone(from) # overloading: both commit and rollback here? if from==old, commit if from==new rollback
	moving_from?(from)
    end

    def move_commit(from)
	moving_from?(from)
    end

    # make interface ready for layer3 use; any ips added subsequently must work
    def layer3 # options, eg rpf?
	unused?
	@if.layer3
	set("l3=true")
    end

    # set port up as an l2 access port
    def access(vlan)
	unused?; can_l2?
	@if.access(vlan)
	set("l2=true,vlan=#{vlan}")
    end

    # set port up as trunk
    def trunk(vlan_list)
	unused?; can_l2?
	unfolded = unfold(vlan_list)
	@if.trunk(vlan_list)
	set("l2=true,vlan_list={#{unfolded}}")
    end

    # set port up as a channel member
    def channel_member(channel)
	unused?; physical?
	@if.channel_member(channel)
    end

    def add_ip(family, ip, nexthop=nil)
	is_l3?
	ip_not_yet_added?
	@if.add_ip(family, ip, nexthop)
	Sql.exec("INSERT INTO ip (ip, l3_switch, l3_interface, nexthop) VALUES($1, $2, $3, $4)", [ip, @switch.to_s, @interface, nexthop])
    end

    def set_param(param, value)
	@if.set_param(param, value)
	set("#{param}='#{value}'") # todo set paramize
    end
    
    def set_params(params)
	used?
	params.each {|p,v| set_param(p,v)} 	
    end

    def add_extra(extra)
	@if.add_extra(extra)
    end

    def del_extra(extra)
	@if.del_extra(extra)
    end
end


class IntLib
    # return matching element(s) from list
    def self.prefix_match(prefix, list)
	ret = list.select{|x| x.upcase.start_with? prefix.upcase}
	raise "unknown interface name (#{interface})" if ret.length == 0
	raise "ambigous interface name (#{interface})" if ret.length > 1
	ret[0]
    end
end

class Cisco
    def initialize(type, interface)
	@type, @interface = type, interface
	@interface_cmds = @global_cmds = @acl_cmds = ""
    end

    def interface(cmd)
	cmd = cmd.join("\n") if cmd.kind_of?(Array)
	@interface_cmds += cmd
    end

    def global(cmd)
	cmd = cmd.join("\n") if cmd.kind_of?(Array)
	@global_cmds += cmd
    end

    def acl(cmd)
	cmd = cmd.join("\n") if cmd.kind_of?(Array)
	@acl_cmds += cmd
    end

    def commit
	Cisco.cmd @global_cmds
	Cisco.cmd "interface #{@interface}\n#{@interface_cmds}"
    end


    def self.cmd(command)
	puts "cisco=>"+command
    end
end


class CiscoInterface < Interface
    # interface_types used in generic switch; must provide at least :bw
    def self.interface_types() {
	"Ethernet"		=> {:bw =>    10, :locigal => false, :l2 =>  true},
	"FastEthernet"		=> {:bw =>   100, :locigal => false, :l2 =>  true},
	"GigabitEthernet"	=> {:bw =>  1000, :locigal => false, :l2 =>  true},
	"TenGigabitEthernet"	=> {:bw => 10000, :locigal => false, :l2 =>  true},
	"Vlan"			=> {:bw =>   nil, :locigal =>  true, :l2 => false},
	"Port-channel"		=> {:bw =>   nil, :locigal =>  true, :l2 =>  true},
	"Loopback"		=> {:bw =>   nil, :locigal =>  true, :l2 => false},
	"Tunnel"		=> {:bw =>   nil, :locigal =>  true, :l2 => false},
    } end

    # todo subinterface (t1/1.300); multi module (t1/1/3)
    def self.parse(intf)
	_, prefix, mod, start, _, last = /^([a-zA-Z-]+)(\d+\/)?(\d+)(-(\d+))?/.match(intf).to_a
	prefix = IntLib.prefix_match(prefix, CiscoInterface.interface_types.keys)
	interface_type = CiscoInterface.interface_types[@prefix]
	[prefix, mod, start, last, interface_type]
    end

    def expand_interface(interface)
	@prefix, @module, @interface_id, @interface_range_last, @interface_type  = CiscoInterface.parse(interface)
	@interface = @prefix + (@module||"") + @interface_id
    end

    def create(description)
	cisco = Cisco.new("interface", @interface)
	# todo: vlans should be managed elsewhere
	if @prefix == "Vlan"
	    cisco.global ["vlan #{@interface_id}", "name name-#{@interface_id}", "exit !nowarning"]
	end
	cisco.interface ["load-interval 30", "no shutdown", "description #{description}"]
	cisco.global "default interface #{@interface}"
	cisco.commit
    end

    def destroy
	if @interface_type[:physical]
	    cisco.interface "shutdown"
	    cisco.global "default interface #{@interface}"
	else
	    cisco.global "no interface #{@interface}"
	    # todo vlan$x del handle vlan removal
	end
    end

    def layer3
	cisco = Cisco.new("interface", @interface)
	if @interface_type[:l2] == true
	    cisco.interface ["no cdp enable", "no switchport"]
	end
	if @switch.features["unnumbered"]
	    cisco.interface ["ip unnumbered Loopback101"] # todo config?
	else
	    ip = getunnumberedip
	    cisco.interface ["ip address #{ip} 255.255.255.0"]
	end
	cisco.interface ["ip flow ingress"] if @switch.features["netflow"]
	cisco.interface ["no ip redirects"]
	cisco.interface ["no cdp enable"] if physical?
	cisco.commit
    end

    def access(vlan)
	cisco = Cisco.new("interface", @interface)
	cisco.interface [
	    "switchport",
	    "switchport mode access",
	    "switchport access vlan #{vlan}",
	    "spanning-tree portfast !nowarning"
	    ]
	if @switch.features["scpps"]
	    cisco.interface "storm-control broadcast level pps 2k 1k" # todo config
	else
	    cisco.interface "storm-control broadcast level 1" # todo config
	end
	# todo: vlans should be managed elsewhere
	cisco.global ["vlan #{vlan}", "name name-#{vlan}", "exit !nowarning"]
	cisco.commit
    end

    def trunk(vlan_list)
	cisco = Cisco.new("interface", @interface)
	cisco.interface [
	    "switchport",
	    "switchport trunk encapsulation dot1q",
	    "switchport trunk allowed vlan #{vlan_list}",
	    "switchport mode trunk",
	    "cdp enable"
	    ]
	cisco.commit
    end

    def channel_member(channel)
	cisco = Cisco.new("interface", @interface)
	cisco.interface ["channel-group #{channel} mode active"] # TODO mode
	cisco.commit	
    end

    def add_ip(family, ip, nexthop=nil)
	mod_ip("", ip, nexthop)
    end

    def del_ip(family, ip, nexthop=nil)
	mod_ip("no", ip, nexthop)
    end

    def mod_ip(del, ip, nexthop)
	nexthop ||= ""
	ip_mask, ip_invmask, ip_base = ip.mask(), ip.hostmask(), ip.base() 
	cisco = Cisco.new("interface", @interface)
	cisco.acl "#{del} permit ip #{ip_base} #{ip_invmask} any"
	if(nexthop =~ /^(.*)\/(.*?)( secondary)?$/)
	    ip2, mask2, sec = $1, $2, $3
	    nextip = nil #new Net::Netmask("$ip2/$mask2");
	    raise "nexthop error" if ip_base != nextip.base or ip_mask != nextip.mask
	    cisco.interface "#{del} ip address #{ip2} #{nextip.mask} #{sec} !nowarning" # using a /31 generates a warning
	else
	    cisco.global "#{del} ip route #{ip_base} #{ip_mask} #{@interface} #{nexthop}"
	end
	cisco.commit
    end

    def set_param(param, value)
	cisco = Cisco.new("interface", @interface)
	case param
	when "description"
	    cisco.interface "description #{value}"
	when "mtu"
	    cisco.interface "mtu #{value}"
	when "acl_in"
	when "acl_out"
	when "bw"
	else
	    raise "unknown parameter"
	end
    end
end

class Ip
    attr_accessor :interface, :ip
    def initialize(interface, ip, nexthop = nil)
	@interface, @ip, @nexthop = interface, ip, nexthop
    end
    def to_s
	@interface.to_s+":"+@ip
    end

    def add
	self
    end
end

class Conf
    def self.get
	return @@config if defined? @@config
	@@config = JSON.parse(File.read('cfg.json'))
    end
end


class Sql
    def self.conn
	return @@conn if defined? @@conn
	@@conn = PG.connect(Conf.get["db"])
    end
    def self.exec(query, params=nil)
	print query+"; "; pp params
    end
end



# Switch("c03").interface("vlan2103").create
# Switch("c03").addmodule("te1/1-4")
# Switch("c03").interface("vlan2103").add_ip("10.0.0.0/30", "10.0.0.1/30")


sw = Switch("c03")
int = sw.interface("te4/4")
int.create("des")
puts int
exit
#ip = int.ip("1.2.3.4")
ip = Switch("c01").interface("fast1").ip("1.2.3.4").add
puts ip
pp ip.class.name
pp ip.interface.switch

Sql.conn.exec( "SELECT * FROM pg_stat_activity" ) do |result|
  puts "     PID | User             | Query"
  result.each do |row|
    puts " %7d | %-16s | %s " %
      row.values_at('procpid', 'usename', 'current_query')
  end
end

Sql.conn.exec("SELECT * FROM if_params WHERE vlan_list is not null") { |r| r.each { |x| puts x } }
