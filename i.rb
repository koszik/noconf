#!/usr/bin/ruby -w

# https://deveiate.org/code/pg/README_rdoc.html

require 'pp'
require 'pg'
require 'json'
require 'ipaddress'
require 'fileutils'

module IPAddress
    class IPv4
	def base
	    u32toip(@u32 & (((1<<(@prefix.to_i))-1) << (32-@prefix.to_i) ))
	end
	def invmask
	    u32toip(1<<(32-@prefix.to_i)-1)
	end
	def mask
	    netmask
	end
	def u32toip(u32)
	    [u32].pack("N").unpack("CCCC").join(".")
	end
    end

    class IPv6
	def base
	    "notsupported"
	end
    end
end


class Switch
    attr_reader :features
    def initialize(switch, sql)
	@switch, @sql = switch, sql
	@features = Sql.get("SELECT switch_features.* FROM switch_features,switches WHERE switch_features.model=switches.model AND switches.id=$1", [switch])
        @if = @if_type.new(self)
    end

    def to_s
	@switch
    end

    def add_module(m)
	prefix, mod, start, last, _interface_type = @if_type.parse(m)
	(start..last).to_a.each { |i| create_interface(prefix+mod+i) }
    end

    def interface(interface)
	Interface.new(self, interface, @if_type.new(self))
    end

    def create_interface(interface)
	_if = Interface.new(self, interface, @if_type.new(self), true)
	_if.create
	_if
    end

    def self.create(smallname, hostname, ip, model)
	Sql.init
	Sql.exec("INSERT INTO switches (id, description, ip, model) VALUES($1, $2, $3, $4)", [smallname, hostname, ip, model]);
	#return if($sw->{virtual});
	if !Conf.noexec
	    FileUtils.mkdir "/home/rrd/data/#{hostname}"
	    FileUtils.chown "rrd", nil, "/home/rrd/data/#{hostname}"
	    FileUtils.symlink "/home/rrd/data/#{hostname}", "/home/rrd/data/#{smallname}"
	    File.open("/home/rrd/scripts/get/update-autoadded", "a") { |f| f.puts "./switch #{smallname} #{ip} &" }
	end
	return Switch(smallname)
    end

    def template
	template = File.read("templates/#{@sql['model']}")
	template.gsub!(/@HOSTNAME@/, @sql['description'])
	template.gsub!(/@MAINIP@/, @sql['ip'])
	puts template
    end
end


class CiscoSwitch < Switch
    def initialize(switch, sql)
        @if_type = CiscoInterface
        super(switch, sql)
    end
end


def Switch(switch)
    Sql.init
    sql = Sql.get("SELECT * FROM switches WHERE id=$1", [switch])
    # if sql.model ...
    CiscoSwitch.new(switch, sql)
end


class Stat
    def self.create(switch, interface)
	interface = interface.gsub(/\//, '.')
	cmd = "echo n | cp -pi /home/rrd/data/xdl.rrd /home/rrd/data/#{switch}/#{interface}"
	puts cmd if Conf.printexec
	`#{cmd}` unless Conf.noexec
    end

    def self.destroy(switch, interface)
	interface = interface.gsub(/\//, '.')
	t = Time.now.to_i
	cmd = "mv /home/rrd/data/#{switch}/#{interface} /home/rrd/data/archive/#{t}-#{switch}-#{interface}; mv /home/rrd/data//mvtmp/#{switch}_#{interface} /home/rrd/data/archive/#{t}-#{switch}-mvtmp-#{interface}"
	puts cmd if Conf.printexec
	`#{cmd}` unless Conf.noexec
    end
end


class Util
    def self.unfold(list)
	list.gsub(/(\d+)-(\d+)/) {($1..$2).to_a.join(",")}
    end

    # convert a list to a list of ranges.
    def compact(v)
	last, start, ret = nil, nil, nil
	v.split(",").each{ |l| l=l.to_i
	    if last != nil
		if last != l - 1
		    if start == last
			ret += ","
		    else
			ret += "-#{last},"
		    end
		    ret += "#{l}"
		    start = l
		end
	    else
		ret = "#{l}"
		start = l
	    end
	    last = l
	}
	ret += "-#{last}" if start != last
	ret
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

    def load
	@if_params = Sql.get("SELECT * FROM if_params WHERE (switch,interface)=($1,$2)", [@switch.to_s, @if.interface])
	@if.if_params = @if_params
    end

    def initialize(switch, interface, _if, create = false)
	@if = _if
	@switch = switch
	@if.expand_interface(interface)
	@interface = @if.interface
	load
	if create and @if_params
	    raise "#{@switch}/#{@interface}: interface already exists"
	end
	if !create and !@if_params
	    raise "#{@switch}/#{@interface}: interface doesn't exist"
	end
    end
    def to_s
	@switch.to_s+"/"+@if.interface
    end

    def ip(ip)
	Ip.new(self, ip)
    end

    def set(cmd)
	Sql.exec("UPDATE if_params SET #{cmd} WHERE (switch,interface)=($1,$2)", [@switch.to_s, @if.interface])
	load
    end

    def set1(cmd, param)
	Sql.exec("UPDATE if_params SET #{cmd} WHERE (switch,interface)=($2,$3)", [param, @switch.to_s, @if.interface])
	load
    end


    def unused?
	raise "#{@switch}/#{@interface}: interface already in use" if @if_params["l2"] or @if_params["l3"]
    end

    def used?
	raise "#{@switch}/#{@interface}: interface not in use" unless @if_params["l2"] or @if_params["l3"]
    end

    def is_l2?
	@if_params["l2"]
    end

    def is_l3?
	raise "#{@switch}/#{@interface}: not in layer3 mode" unless @if_params["l3"]
    end

    def not_found?
	raise "#{@switch}/#{@interface}: interface already exists" unless @if_params == nil
    end

    def can_l2?
	raise "#{@switch}/#{@interface}: interface not capable for layer2 operation" unless @if.interface_type[:l2]
    end

    def physical?
	raise "#{@switch}/#{@interface}: interface is not physical" unless @interface_type[:physical]
    end

    def remove
	used?
    end

    # create interface (insert phys, create logical)
    def create # addmodule, vlan, po
	# unused is checked during init
	Sql.exec "INSERT INTO if_params (switch, interface, l2, l3, bandwidth) VALUES($1, $2, false, false, $3)", [@switch.to_s, @if.interface, @if.interface_type[:bw]]
	load
    end

    def destroy
	used?
	if @if_params["l3"]
	    # todo check SELECT COUNT(*) AS cnt FROM if_params WHERE (l3_switch, l3_interface)=('$sw','$p->{interface}') AND (switch,interface)!=('$sw','$p->{interface}')
	    Ip.list(@switch, @interface).each { |ip|
		del_ip(ip["ip"], ip["nexthop"])
	    }
	    # remove acl
	end
	@if.destroy
	Stat.destroy(@switch.to_s, @if.interface)
	if @if.interface_type[:logical]
	    Sql.exec "DELETE FROM if_params WHERE (switch, interface)=($1,$2)", [@switch.to_s, @if.interface]
	else
	    Sql.exec "UPDATE if_params SET l2=false,l3=false WHERE (switch, interface)=($1,$2)", [@switch.to_s, @if.interface]
	end
	load
    end

    def clone(from)
	unused?
    end

    def unclone(from) # overloading: both commit and rollback here? if from==old, commit if from==new rollback
	moving_from?(from)
    end

    def move_commit(from)
	moving_from?(from)
    end

    def get_config
	used?
	if @if_params["l3"]
	    @if.layer3
	    Ip.list(@switch, @interface).each { |ip|
		@if.add_ip(ip["ip"], ip["nexthop"])
	    }
	elsif @if_params["l2"]
	    if @if_params["vlan_list"]
		@if.trunk(Util.compact(@if_params["vlan_list"][1..-2]))
	    elsif @if_params["vlan"]
		@if.access(@if_params["vlan"])
	    end
	end
	@if.add_extra(@if_params["if_extra"]) if @if_params["if_extra"]
	["description", "mtu"].each { |v|
	    @if.set_param(v, @if_params[v]) if @if_params[v]
	}
    end

    # make interface ready for layer3 use; any ips added subsequently must work
    def layer3 # options, eg rpf?
	unused?
	@if.layer3
	set("l3=true,rpf=true")
	Stat.create(@switch.to_s, @if.interface)
    end

    # set port up as an l2 access port
    def access(vlan)
	unused?; can_l2?
	@if.access(vlan)
	set("l2=true,vlan=#{vlan}")
	Stat.create(@switch.to_s, @if.interface)
    end

    # set port up as trunk
    def trunk(vlan_list)
	unused?; can_l2?
	unfolded = Util.unfold(vlan_list)
	@if.trunk(vlan_list)
	set("l2=true,vlan_list='{#{unfolded}}'")
	Stat.create(@switch.to_s, @if.interface)
    end

    # set port up as a channel member
    def channel_member(channel)
	unused?; physical?
	@if.channel_member(channel)
	Stat.create(@switch.to_s, @if.interface)
    end

    def add_ip(ip, nexthop=nil)
	is_l3?
	secondary = Ip.primaryv4?(@switch, @interface)
	ipa = IPAddress.parse(ip)
	nexthopa = nil
	if nexthop
	    nexthopa = IPAddress.parse(nexthop)
	    raise "nexthop error" if ipa.base != nexthopa.base or ipa.prefix != nexthopa.prefix
	end
	ip = Ip.new(ip, @switch.to_s, @interface, nexthop, secondary)
	ip.unused?
	@if.add_ip(ipa, nexthopa, secondary)
	ip.add
    end

    def del_ip(ip, nexthop=nil)
	is_l3?
	ipa = IPAddress.parse(ip)
	ip = Ip.new(ip, @switch.to_s, @interface, nexthop)
	ip.used?
	if nexthop
	    nexthopa = IPAddress.parse(nexthop)
	    raise "nexthop error" if ipa.base != nexthopa.base or ipa.mask != nexthopa.mask
	end
	@if.del_ip(ipa, nexthopa, ip.secondary?)
	ip.remove
    end

    def set_param(param, value)
	used?
	@if.set_param(param, value)
	set("#{param}='#{value}'") # todo set paramize
    end

    def set_params(params)
	params.each {|p,v| set_param(p,v)}
    end

    def add_extra(extra)
	used?
	@if.add_extra(extra)
	set1("if_extra=COALESCE(if_extra||'\n','')||$1", extra)
    end

    def del_extra(extra)
	used?
	@if.del_extra(extra)
    end

    def commit
	@if.commit
    end
end


class IntLib
    # return matching element(s) from list
    def self.prefix_match(prefix, list)
	ret = list.select{|x| x.upcase.start_with? prefix.upcase}
	raise "unknown interface prefix (#{prefix})" if ret.length == 0
	raise "ambigous interface prefix (#{prefix})" if ret.length > 1
	ret[0]
    end
end


class Cisco
    def initialize(type, interface)
	@type, @interface = type, interface
	@interface_cmds = "interface  #{@interface}\n"
	@global_cmds = @global_end_cmds = @acl_cmds = ""
    end

    def interface(cmd)
	cmd = cmd.join("\n ") if cmd.kind_of?(Array)
	@interface_cmds += " " + cmd + "\n"
    end

    def global(cmd)
	cmd = cmd.join("\n") if cmd.kind_of?(Array)
	@global_cmds += cmd + "\n"
    end

    def global_end(cmd)
	cmd = cmd.join("\n") if cmd.kind_of?(Array)
	@global_end_cmds += cmd + "\n"
    end

    def aclname(v, acl)
	if v == :ipv4
	    @acl_cmds = "ip access-list extended #{acl}\n"
	else
	    @acl_cmds = "ipv6 acces-list #{acl}\n"
	end
    end

    def acl(cmd)
	cmd = cmd.join("\n ") if cmd.kind_of?(Array)
	@acl_cmds += " " + cmd + "\n"
    end


    def commit
	Cisco.cmd @global_cmds + @acl_cmds + @interface_cmds + @global_end_cmds
	initialize(@type, @interface)
    end

    def self.cmd(command)
	puts "!cstart\n"+command+"\!cend"
    end
end


class CiscoInterface
    attr_accessor :interface_range_last, :interface, :interface_type, :interface_id, :prefix, :if_params

    def initialize(switch)
	@switch = switch
    end

    # interface_types used in generic switch; must provide at least :bw
    def self.interface_types() {
	"Ethernet"		=> {:bw =>    10, :logical => false, :l2 =>  true},
	"FastEthernet"		=> {:bw =>   100, :logical => false, :l2 =>  true},
	"GigabitEthernet"	=> {:bw =>  1000, :logical => false, :l2 =>  true},
	"TenGigabitEthernet"	=> {:bw => 10000, :logical => false, :l2 =>  true},
	"Vlan"			=> {:bw =>   nil, :logical =>  true, :l2 => false},
	"Port-channel"		=> {:bw =>   nil, :logical =>  true, :l2 =>  true},
	"Loopback"		=> {:bw =>   nil, :logical =>  true, :l2 => false},
	"Tunnel"		=> {:bw =>   nil, :logical =>  true, :l2 => false},
    } end

    # todo subinterface (t1/1.300); multi module (t1/1/3)
    def self.parse(intf)
	_, prefix, mod, start, _, last = /^([a-zA-Z-]+)(\d+\/)?(\d+)(-(\d+))?/.match(intf).to_a
	prefix = IntLib.prefix_match(prefix, CiscoInterface.interface_types.keys)
	interface_type = CiscoInterface.interface_types[prefix]
	[prefix, mod, start, last, interface_type]
    end

    def expand_interface(interface)
	@prefix, @module, @interface_id, @interface_range_last, @interface_type  = CiscoInterface.parse(interface)
	@interface = @prefix + (@module||"") + @interface_id
	@cisco = Cisco.new("interface", @interface)
    end

    def layer2_init
	if !@interface_type[:logical] # TODO: in case of 'po' it could be used yet it's logical
	    @cisco.interface "no cdp enable"
	end
	@cisco.interface ["load-interval 30", "no shutdown"]
	@cisco.global "default interface #{@interface}"
    end

    def destroy
	if !@interface_type[:logical]
	    @cisco.interface "shutdown"
	    @cisco.global "default interface #{@interface}"
	else
	    @cisco.global_end "no interface #{@interface}"
	    # todo vlan$x del handle vlan removal
	end
    end

    def layer3
	# todo: vlans should be managed elsewhere
	if @prefix == "Vlan"
	    @cisco.global ["vlan #{@interface_id}", "name name-#{@interface_id}", "exit !nowarning"]
	end
	if @interface_type[:l2]
	    @cisco.interface ["no cdp enable", "no switchport"]
	end
	if @switch.features["unnumbered"]
	    @cisco.interface ["ip unnumbered Loopback101"] # todo config
	else
	    # TODO getunnumberedip
	    ip = getunnumberedip
	    @cisco.interface ["ip address #{ip} 255.255.255.0"]
	end
	@cisco.interface ["ip flow ingress"] if @switch.features["netflow"]
	@cisco.interface ["no ip redirects", "no shutdown", "load-interval 30"]
	@cisco.interface ["no cdp enable"] unless @interface_type[:logical]
    end

    def access(vlan)
	layer2_init
	@cisco.interface [
	    "switchport",
	    "switchport mode access",
	    "switchport access vlan #{vlan}",
	    "spanning-tree portfast !nowarning"
	    ]
	if @switch.features["scpps"]
	    @cisco.interface "storm-control broadcast level pps 2k 1k" # todo config
	else
	    @cisco.interface "storm-control broadcast level 1" # todo config
	end
	# todo: vlans should be managed elsewhere
	@cisco.global ["vlan #{vlan}", "name name-#{vlan}", "exit !nowarning"]
    end

    def trunk(vlan_list)
	layer2_init
	@cisco.interface [
	    "switchport",
	    "switchport trunk encapsulation dot1q",
	    "switchport trunk allowed vlan #{vlan_list}",
	    "switchport mode trunk",
	    "cdp enable"
	    ]
    end

    def channel_member(channel)
	@cisco.interface ["channel-group #{channel} mode active"] # TODO mode
    end

    def add_ip(ip, nexthop, secondary=nil)
	mod_ip("", ip, nexthop, secondary)
    end

    def del_ip(ip, nexthop, secondary=nil)
	mod_ip("no", ip, nexthop, secondary)
    end

    def mod_ip(del, ip, nexthop, secondary)
	if ip.to_s =~ /:/
	    mod_ip6(del, ip, nexthop)
	else
	    mod_ip4(del, ip, nexthop, secondary)
	end
    end

    def mod_ip4(del, ip, nexthop, secondary)
	if(!nexthop or nexthop.prefix == 32)
	    @cisco.global_end "#{del} ip route #{ip.base} #{ip.mask} #{@interface} #{nexthop}"
	else
	    sec = secondary ? "secondary" : ""
	    @cisco.interface "#{del} ip address #{nexthop} #{nexthop.mask} #{sec} !nowarning" # using a /31 generates a warning
	end
	if @if_params["rpf"] ## TODO support urpf?
	    if true # !acl
		acl = "P#{@interface}-IN"
		@cisco.interface "ip access-group #{acl} in"
	    end
	    @cisco.aclname(:ipv4, acl)
	    @cisco.acl ["no deny ip any any log-input", "no deny ip any any"]
	    @cisco.acl "#{del} permit ip #{ip.base} #{ip.invmask} any"
	end
    end

    def mod_ip6(del, ip, nexthop)
	if(!nexthop or nexthop.prefix == 128)
	    @cisco.global "#{del} ipv6 route #{ip}/#{ip.prefix} #{nexthop}"
	else
	    @cisco.interface "#{del} ipv6 address #{nexthop}/#{nexthop.prefix}"
	end

	if @if_params["rpf"]
	    @cisco.acl ["#{del} permit ipv6 FE80::/10 #{ip}", "#{del} permit ipv6 #{ip} any"]
	    raise "no rpf support yet"
	end
    end

    def set_param(param, value)
	case param
	when "description"
	    @cisco.interface "description #{value}"
	when "mtu"
	    @cisco.interface "mtu #{value}"
	when "acl_in"
	when "acl_out"
	when "bw"
	when "rpf" ## TODO
	else
	    raise "unknown parameter"
	end
    end

    def add_extra(extra)
	@cisco.interface extra
    end

    def commit
	@cisco.commit if defined?@cisco
    end
end

class BladeInterface
    attr_accessor :interface_range_last, :interface, :interface_type, :interface_id, :prefix, :if_params

    def initialize(switch)
	@switch = switch
    end

    def self.parse(intf)
	_, prefix, mod, start, _, last = /^([a-zA-Z-]+)(\d+\/)?(\d+)(-(\d+))?/.match(intf).to_a
	prefix = IntLib.prefix_match(prefix, CiscoInterface.interface_types.keys)
	interface_type = CiscoInterface.interface_types[prefix]
	[prefix, mod, start, last, interface_type]
    end

    def expand_interface(interface)
	@interface = interface
	@cisco = Cisco.new("interface port", @interface)
    end

    def destroy
	@cisco.interface "shutdown"
	@cisco.global "default interface #{@interface}"
    end

    def access(vlan)
	@cisco.interface "pvid #{vlan}"
    end

    def trunk(vlan_list)
	@cisco.interface "tagging"
    end

    def channel_member(channel)
	@cisco.interface ["channel-group #{channel} mode active"] # TODO mode
    end

    def set_param(param, value)
	case param
	when "description"
	    @cisco.interface "name #{value}"
	when "mtu"
	    @cisco.interface "mtu #{value}"
	else
	    raise "unknown parameter"
	end
    end

    def add_extra(extra)
	@cisco.interface extra
    end

    def commit
	@cisco.commit if defined?@cisco
    end
end

class Vlan
    def initialize(vlan)
	@sql = Sql.get("SELECT * FROM vlan WHERE vlan=$1", [vlan])
    end

    def self.create(vlan)
	Sql.exec()
    end

    def add
        Sql.exec("INSERT INTO vlan (vlan) VALUES($1)", [vlan])
    end

    def remove
	Sql.exec("DELETE FROM vlan WHERE vlan=$1", [vlan])
    end
end


class Ip
    attr_accessor :interface, :ip
    def initialize(ip, switch, interface, nexthop, secondary=nil)
	nexthop ||= "0.0.0.0/0" # TODO ipv6
	@interface, @ip, @nexthop, @switch, @secondary = interface, ip, nexthop, switch, secondary
	@sql = Sql.get("SELECT * FROM ip WHERE (ip, l3_switch, l3_interface, nexthop)=($1, $2, $3, $4)", [ip, switch, interface, nexthop])
    end

    def unused?
	raise "#{@switch}/#{@interface}:#{@ip}/#{@nexthop}: exact route already exists!" if @sql
    end

    def used?
	raise "#{@switch}/#{@interface}:#{@ip}/#{@nexthop}: exact route doesn't exist!" unless @sql
    end

    def secondary?
	@sql['secondary']
    end

    def self.primaryv4?(switch, interface)
	r = Sql.get("SELECT COUNT(*) AS primary FROM ip WHERE network(ip)=network(nexthop) and family(ip)=4 AND (l3_switch, l3_interface)=($1, $2)", [switch, interface])
	r['primary'].to_i > 0
    end

    def self.list(switch, interface)
	Sql.conn.exec_params("SELECT family(ip),text(ip) ip,nexthop FROM ip WHERE (l3_switch, l3_interface)=($1, $2) ORDER BY secondary", [switch, interface])
    end

    def add
	Sql.exec("INSERT INTO ip (ip, l3_switch, l3_interface, nexthop, secondary) VALUES($1, $2, $3, $4, $5)", [@ip, @switch, @interface, @nexthop, @secondary])
    end

    def remove
	Sql.exec("DELETE FROM ip WHERE (ip, l3_switch, l3_interface, nexthop)=($1, $2, $3, $4)", [@ip, @switch, @interface, @nexthop])
    end
end


class Conf
    def self.get
	return @@config if defined? @@config
	@@config = JSON.parse(File.read('cfg.json'))
    end
    def self.nosql
return false
#	true
    end
    def self.printsql
	true
    end
    def self.noexec
#return false
	true
    end
    def self.printexec
	true
    end
end


class Sql
    def self.init
	return @@conn if defined? @@conn
	@@conn = PG.connect(Conf.get["db"])
	@@conn.exec "BEGIN"
	@@conn
    end
    def self.exec(query, params=nil)
	if Conf.printsql
	    print query+"; "; pp params
	end
	if !Conf.nosql
	    @@conn.exec(query, params)
	end
    end
    def self.get(query, params)
	r = @@conn.exec_params(query, params)
	begin
	    r = r[0]
	rescue IndexError
	    return nil
	end
	r.each { |key,x| if x == "t"; r[key]=true elsif x == "f"; r[key]=false; end } # todo ugly
	r
    end
    def self.commit
	@@conn.exec "COMMIT"
    end
end


# Switch("c03").interface("vlan2103").create
# Switch("c03").addmodule("te1/1-4")
# Switch("c03").interface("vlan2103").add_ip("10.0.0.0/30", "10.0.0.1/30")

=begin
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
=end
