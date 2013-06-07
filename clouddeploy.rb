#!/usr/bin/env ruby

require 'gli'
require 'pp'
require 'fog'
require 'date'
require 'mysql2'

begin # XXX: Remove this begin/rescue before distributing your app
require 'clouddeploy'
rescue LoadError
  STDERR.puts "In development, you need to use `bundle exec bin/clouddeploy`"
  STDERR.puts "At install-time, RubyGems will make sure lib, etc. are in the load path"
  exit 64
end

include GLI::App

def option_cat(a,b)
  if a != ""
    (a + ", " + b)
  else
    b
  end
end

account_id = "XXXXXXXXX"
recipeVersion = "2.1"

ami_map =  {            
            
  'Base' => {
      :before_recipes => "role[base-#{recipeVersion}]", 
      :after_recipes => "recipe[servers-#{recipeVersion}::monitor_setup]"
                  },
  'WebBase' => {
      :before_recipes => "role[webserver-#{recipeVersion}]",
      :after_recipes => "recipe[servers-#{recipeVersion}::monitor_setup],recipe[servers-#{recipeVersion}::restart_nginx]"
                     },

  'WebRedisBase' => {
       :before_recipes => "role[webserver-#{recipeVersion}],recipe[-servers-#{recipeVersion}::redis]",
       :after_recipes => "recipe[servers-#{recipeVersion}::monitor_setup],recipe[servers-#{recipeVersion}::restart_nginx]",
                         }
}

recipe_map ={
  'test_service' => "recipe[servers-#{recipeVersion}::test_service]",
  'test2_service' => "recipe[servers-#{recipeVersion}::test2_service]",
  'test3_service' => "recipe[servers-#{recipeVersion}::test3_service]",
  'test_worker' => "recipe[servers-#{recipeVersion}::test_worker]",
  'test2_worker' => "recipe[servers-#{recipeVersion}::test2_worker]"
}
  
key_map = { 
            :east => 'USEast',
            :west => 'USWestOr'
          }

zone_map = {
              :east => {
                            :zone_base => "us-east-1",
                            :nzones => 4 
                          },
    
               :west => {
                            :zone_base => "us-west-2",
                            :nzones => 3 
                          }
}


aws = nil
elb = nil

program_desc 'Deploy Services to cloud providers'

version Clouddeploy::VERSION

desc 'be chatty'
switch [:verbose,:v]

desc 'region'
default_value 'west'
arg_name 'region'
flag [:region,:r]

desc 'aws cred file'
default_value "#{ENV["HOME"]}/.ec2/awsCredentialFile"
arg_name "keyfile"
flag [:keyfile,:k]

desc "Don't really deploy anything"
switch [:pretend,:p]

#############################################################################################

desc 'Launch a node with the specified services'
arg_name 'service1 service2 ...'

command [:launch, :l] do |c|
  c.desc 'do not quick boot - run enforcement recipies'
  c.switch [:noquickboot,:n]

  c.desc 'force deployment when > 1 instance and > 1 service is specified'
  c.switch :forcemulti

  c.desc 'launch in this/these availability zone(s)'
  c.default_value 'c'
  c.flag [:zones,:z]

  c.desc 'launch using specified execution environment [one of development, staging or production]'
  c.default_value 'development'
  c.flag [:ex_env,:x]

  c.desc 'using the specified image snapshot [one of Base, WebBase, WebRedisBase]'
  c.default_value 'WebRedisBase'
  c.flag [:baseimage,:b]

  c.desc 'launch using specified instance flavor [one of c1.medium, m1.medium, m1.large, m1.small or t1.micro]'
  c.default_value 'c1.medium'
  c.flag [:itype,:i]

  c.desc 'launch using specified security group'
  c.default_value 'Services'
  c.flag [:sgroup,:s]

  c.desc 'launch the specified number of instances'
  c.default_value 1
  c.flag [:count,:c]

  c.desc 'run as specified user'
  c.default_value "root"
  c.flag [:user,:u]

  c.desc 'name of node'
  c.default_value ""
  c.flag [:nodename,:N]

  c.desc 'name of loadbalancer to register with'
  c.default_value ""
  c.flag [:elbname]
  
  c.desc 'do not delete old instance'
  c.switch [:nodestroy,:D]

  c.action do |global_options,options,args|
    # Your command logic here
    # If you have any errors, just raise them
    # raise "that command made no sense"
    
    image_name = options[:baseimage] + "-" + options[:ex_env]

    image = aws.images.all("tag:Name"=>image_name,"owner-id"=>account_id.to_s).last

    raise "Unknown image specified #{image_name}" if image == nil
    #raise "Service name(s) required" if args.length == 0

    secgroup = aws.security_groups.all("group-name"=>options[:sgroup]).last

    raise "Unknown security group specified #{options[:sgroup]}" if secgroup == nil

     if options[:noquickboot]
       before_recipes = ami_map[options[:baseimage]][:before_recipes]
     else
       before_recipes = ""
     end

     before_recipes = option_cat(before_recipes,"recipe[servers-#{recipeVersion}::nodeetup]") ## runs default recipe
     after_recipes = ami_map[options[:baseimage]][:after_recipes]
     
     if options[:ex_env] != "development"
       after_recipes = option_cat(after_recipes,"recipe[chef-client]")
     end

     region = global_options[:region].to_sym
     
     
     if args.length > 0
       services = args
     else
       services = []
     end
     
     #raise("Must specify at least 1 service") if services == nil
       
     count = options[:count].to_i

     raise "instance count > 1 and multiple services specified.  Use --forcemulti to override" if(count > 1 && services.length > 1 && !options[:forcemulti])

     zones = options[:zones].split(",")

     if zones.length < count
        idx = count - 1
        count.times { zones[idx] = ("a".."d").to_a[idx % zone_map[region][:nzones]]; idx = idx - 1 }
      end

      if global_options[:pretend]
         puts ""
         puts "I would run the following commands: "
         puts ""
      end

      begin
         count = count - 1
         if options[:nodename] == ""
           nodename = "#{services[0]}_#{options[:ex_env]}_#{count}" 
         else
           nodename = options[:nodename] + "_" + count.to_s
         end
         
         zone = zone_map[region][:zone_base] + zones[count]
         common_launch_opts =  " -N #{nodename} -i ~/.ssh/#{key_map[region]}.pem -x #{options[:user]} -d nukuawslinux -E #{options[:ex_env]}"
         recipes = '"'
         recipes += before_recipes if before_recipes != ""
         
         services.each do |service|
           raise "Unknown service '#{service}'" if recipe_map[service] == nil
           recipes += ("," + recipe_map[service]) if recipe_map[service] != ""
         end
         
         recipes += "," + after_recipes if after_recipes != ""
         recipes += '"'

         launchcmd = "knife bootstrap -r " + recipes + common_launch_opts

         chef_cleanup_string = "knife node delete #{nodename} -y; knife client delete #{nodename} -y"

         if global_options[:pretend] || global_options[:verbose]
           puts chef_cleanup_string
           puts launchcmd
         end

         if !global_options[:pretend]
           `#{chef_cleanup_string} 1>&2`
           
           print "booting server...Launching a #{options[:itype]} instance in zone #{zone} with image #{image.id}"

           server = aws.servers.create(
             :image_id => image.id,
             :flavor_id => options[:itype],
             :key_name => key_map[region],
             :username=>options[:user],
             :private_key_path=>"~/.ssh/#{key_map[region]}.pem",
             :security_group_ids=>secgroup.group_id,
             :availability_zone=>zone
           )
            
          server.wait_for { print "."; ready? }
            print "\nwaiting for sshd"
            server.wait_for {
              print "."
              begin
                server.ssh 'whoami'
              rescue
                print "#"
              end
            }
            
            oldservers = []
            
            if !options[:nodestroy]
              print "looking for instances to terminate...\n"

              oldservers = aws.servers.all("tag:Name"=> nodename, 
                                           "tag:System" => options[:ex_env], 
                                           "owner-id"=> account_id,
                                           "instance-state-name" => "running")
              print "found #{oldservers.count}\n"
            end

            aws.tags.create(:resource_id => server.id, :key => "System", :value => options[:ex_env])
            aws.tags.create(:resource_id => server.id, :key => "NodeName", :value => nodename)
            aws.tags.create(:resource_id => server.id, :key => "Name", :value => nodename)
            if (elbname = options[:elbname]) != ""
              aws.tags.create(:resource_id => server.id, :key => "ELB", :value => elbname)
              print "registering with #{elbname}"
              elb.register_instances([server.id],elbname)
            end
            
            services_str = services[0]
            
            if services.length > 1
              services.each_with_index do |s,i| 
                next if i == 0
                services_str += " #{s}"
              end
            end

            aws.tags.create(:resource_id => server.id, :key => "Services", :value => services_str)

            launchcmd = "knife bootstrap #{server.dns_name} -r " + recipes + common_launch_opts

            print "\nbootstrapping server @ #{server.dns_name}\n#{launchcmd}\n"

            `#{launchcmd} 1>&2`
            
            if oldservers && oldservers.count > 0
              print"terminating #{oldservers.count} old servers\n"
              oldservers.each do |old|  
                print "Terminating #{old.id}\n"
                if (elbname = old.tags["ELB"]) != nil
                  print "Deregistering from #{elbname}\n"
                  elb.deregister_instances([old.id],elbname)
                end
                old.destroy
              end            
            end
            
          end

      end until count == 0

    end
end

##################################################################################################

desc "rebuild or redeploy the specified service"
arg_name 'service_name'

command [:service,:svc] do |c|
  
  c.desc 'use the specified execution environment [one of development, staging or production]'
  c.default_value 'development'
  c.flag [:ex_env,:x]

  c.desc 'user to log in aas'
  c.default_value 'root'
  c.flag [:user,:u]

  c.desc "rebuild (rebundle) the specified service"
  c.command [:rebuild]  do |rebuild|
    rebuild.action do |global_options,options,args|

      if args.length != 1 
        raise "Invalid argument - service was specified"
      end
      
     all_servers = aws.servers.all( "tag:System" => options[:ex_env],
                                   "owner-id"=> account_id,
                                   "instance-state-name" => "running")
      servers = []
      
      print "No servers were detected for tag:System #{options[:ex_env]}\n"
      
      all_servers.each do |s|
        svcs = s.tags["Services"]
        if svcs 
          servers << s if svcs.include? args[0]
        end
      end

      servers.each do |srvr|
        print "Rebuilding #{args[0]} @ #{srvr.public_ip_address}\n"
    
        cmd = "cd /var/www/#{args[0]}/current;bundle update;bundle install;touch tmp/restart.txt"
        cmdstring = "ssh -i ~/.ssh/#{key_map[global_options[:region].to_sym]}.pem #{options[:user]}@#{srvr.public_ip_address} \"#{cmd}\""

        if global_options[:pretend] || global_options[:verbose]
          puts "runninging command: #{cmdstring}"
        end
      
        `#{cmdstring} 1>&2` if !global_options[:pretend]
      
      end
    
    end
  
  end

  c.desc "redeploy the specified service"
  c.command [:redeploy]  do |redeploy|
    redeploy.action do |global_options,options,args|

      if args.length != 1 
        raise "Invalid argument"
      end
    
      all_servers = aws.servers.all( "tag:System" => options[:ex_env],
                                    "owner-id"=> account_id,
                                    "instance-state-name" => "running")
       servers = []

       all_servers.each do |s|
         svcs = s.tags["Services"]
         if svcs 
           servers << s if svcs.include? args[0]
         end
       end

       servers.each do |srvr|
         print "Redeploying #{args[0]} @ #{srvr.public_ip_address}\n"

         cmd = "cd /var/www;rm -r #{args[0]};rm /var/chef/cache/revision-deploys/#{args[0]};chef-client"
         cmdstring = "ssh -i ~/.ssh/#{key_map[global_options[:region].to_sym]}.pem #{options[:user]}@#{srvr.public_ip_address} \"#{cmd}\""

         if global_options[:pretend] || global_options[:verbose]
           puts "running command: #{cmdstring}"
         end
      
         `#{cmdstring} 1>&2` if !global_options[:pretend]
       end
    
    end
  
  end
  
end

##################################################################################################

desc "manage the boot image set"
arg_name 'none'

command [:bootimages,:bi] do |c|
  
  c.desc 'launch using specified instance flavor [one of c1.medium, m1.medium, m1.large, m1.small or t1.micro]'
  c.default_value 'c1.medium'
  c.flag [:itype,:i]

  c.desc 'launch using specified security group'
  c.default_value 'NukuServices'
  c.flag [:sgroup,:s]
  
  c.desc 'launch using specified execution environment [one of development, staging or production]'
  c.default_value 'development'
  c.flag [:ex_env,:x]

  c.desc 'Create a boot image snapshot set from the latest pristine amazon ami image'
  
  c.command [:create,:c]  do |create|
    
    create.action do |global_options,options,args|
    
      if args.length != 0 
        raise "Invalid argument"
      end
    
      # find latest amazon image
    
      images = aws.images.all("owner-alias"=>"amazon",
                            "image-type"=>"machine",
                            "architecture"=>"x86_64",
                            "root-device-type"=>"ebs")
  
      imgs = images.select { |a| a.name =~ /amzn-ami-pv-/ }
      imgs.sort! { |a,b| b.name <=> a.name }
      root_ami = imgs[0].id 
    
      raise "Amazon AMI Base image not found" if root_ami == nil
    
      region = global_options[:region].to_sym
    
      %w{Base WebBase WebRedisBase}.each do |ami_tag|
      
        ami_tag += "-#{options[:ex_env]}"
        
        # launch it
        
        puts "Creating #{ami_tag}"
        
        if global_options[:pretend]
            puts ""
            puts "I would run the following commands: "
            puts ""
        end

        secgroup = aws.security_groups.all("group-name"=>options[:sgroup]).last

        nodename = "Bootstrap"
        zone = zone_map[region][:zone_base] + 'c'
        common_launch_opts =  " -N #{nodename} -i ~/.ssh/#{key_map[region]}.pem -x ec2-user -d nukuawslinux -E #{options[:ex_env]} --sudo"

        launchcmd = "knife bootstrap -r " + ami_map[ami_tag.split("-")[0]][:before_recipes] + common_launch_opts

        chef_cleanup_string = "knife node delete #{nodename} -y; knife client delete #{nodename} -y"

        if ((global_options[:pretend] || global_options[:verbose]))
          puts chef_cleanup_string 
          puts launchcmd
        end

        if !global_options[:pretend]
          `#{chef_cleanup_string} 1>&2`

          print "booting server...Launching a #{options[:itype]} instance in zone #{zone} with image #{root_ami}\n"

          server = aws.servers.create(
            :image_id => root_ami,
            :flavor_id => options[:itype],
            :key_name => key_map[region],
            :username=>"ec2-user",
            :private_key_path=>"~/.ssh/#{key_map[region]}.pem",
            :security_group_ids=>secgroup.group_id,
            :availability_zone=>zone
          )

          server.wait_for { print "."; ready? }

          print "\nwaiting for sshd"
          server.wait_for { 
            print "."
              begin
              server.ssh 'whoami' 
              rescue
                print "#"
              end
          }

          # update it
      
          print "\nUpdating..."

          server.ssh("sudo yum update -y;sudo gem update --no-ri --no-rdoc")
      
          # bootstrap our code onto it

          launchcmd = "knife bootstrap #{server.dns_name} -r " + ami_map[ami_tag.split("-")[0]][:before_recipes] + common_launch_opts

          print "\nbootstrapping server @ #{server.dns_name}\n#{launchcmd}\n"

          `#{launchcmd} 1>&2`

        
          ### sync filesystems
        
          print "\nwaiting for sync"
        
          server.wait_for { 
            print "."
              begin
              server.ssh 'sync;sync' 
              rescue
                print "#"
              end
          }
    
          # snapshot the image
    
          root_vol_id = server.block_device_mapping[0]["volumeId"]
        
          ami_name = ami_tag + "-" + DateTime.now.strftime("%Y%m%d%H%M")
        
          print "\nSnapshotting vol #{root_vol_id} to #{ami_name}"
     
          snap = aws.snapshots.create(
            :name => ami_name,
            :desc => ami_name,
            :volume_id => root_vol_id
            )
    
          print "\nwaiting for snapshot.."
          snap.wait_for { print "."; ready? }
    
          new_block_map = [
              {
                "DeviceName" => "/dev/sda", 
                "SnapshotId" => snap.id, 
                "VolumeSize"=> snap.volume_size, 
                "DeleteOnTermination" => true
              }
          ]
    
            # register new ami
        
          aki = aws.images.all(
              "owner-alias" => "amazon",
              "image-type" => "kernel",
              "architecture" => "x86_64",
              "manifest-location" => "ec2-public-images-#{zone_map[region][:zone_base]}/pv-grub-hd0_*"
              ).last
    
          raise("\nNo kernel found") if aki == nil
    
          print "\negistering new ami.."

          new_ami = aws.register_image(
              ami_name,
              ami_name,
              "/dev/sda1",
              new_block_map,
              {
                "KernelId" => aki.id,
                "Architecture" => "x86_64"
              }
          )
    
          print "\nwaiting for ami to register..."
        
          new_ami = aws.images.all("image-id" => new_ami.body["imageId"]).last
          new_ami.wait_for { print "."; ready? }    
        
          print "\n"
    
          # delete tag from old image
    
          old_ami = aws.images.all("tag:Name"=>ami_tag.to_s,"owner-id"=>account_id.to_s).first
        
          if old_ami != nil
            tags = aws.tags.all("resource-id"=>old_ami.id) 
    
            tags.each do |t|
              if t.key == "Name"
                t.destroy
              end
            end
          end
    
          # tag new one

          aws.tags.create(:resource_id => new_ami.id, :key => "Name", :value => ami_tag)
        
          server.destroy  ## delete the boot server
        
          if old_ami != nil ## delete the old image        
            print "deregistering image #{old_ami.id}\n"
            aws.deregister_image(old_ami.id)  
            print "waiting for deregister...."
            sleep 10
          
            snap = aws.snapshots.get(old_ami.block_device_mapping[0]["snapshotId"])
         
            if snap != nil
              print "deleteing snapshot #{snap.id}\n"
              snap.destroy
            else
              print "WARNING: snapshot #{snap.id} not found!\n"
            end
          end
        
          root_ami = new_ami.id
        end
      end    
    end
  end ### create
  
  c.desc 'apply updates to the existing image set'
  c.command [:update,:u] do |update|

    update.action do |global_options,options,args|

      if args.length != 0 
        raise "Invalid argument"
      end

      region = global_options[:region].to_sym

      %w{Base WebBase WebRedisBase}.each do |ami_tag|

        ami_tag += "-#{options[:ex_env]}"
 
        image = aws.images.all("tag:Name"=>ami_tag.to_s,"owner-id"=>account_id.to_s).first
        root_ami = image.id

        # launch it

        if global_options[:pretend]
          if options[:updateonly]
            puts "Applying security updates only"
          else
            puts ""
            puts "I would run the following commands: "
            puts ""
          end
        end

        secgroup = aws.security_groups.all("group-name"=>options[:sgroup]).last

        nodename = "Bootstrap"
        zone = zone_map[region][:zone_base] + 'c'
        common_launch_opts =  " -N #{nodename} -i ~/.ssh/#{key_map[region]}.pem -x ec2-user -d nukuawslinux -E development --sudo"

        launchcmd = "knife bootstrap -r " + ami_map[ami_tag.split("-")[0]][:before_recipes] + common_launch_opts

        chef_cleanup_string = "knife node delete #{nodename} -y; knife client delete #{nodename} -y"

        if ((global_options[:pretend] || global_options[:verbose]) && !options[:updateonly])
          puts chef_cleanup_string 
          puts launchcmd
        end

        if !global_options[:pretend]
          `#{chef_cleanup_string} 1>&2`

          print "booting server...Launching a #{options[:itype]} instance in zone #{zone} with image #{root_ami}\n"

          server = aws.servers.create(
            :image_id => root_ami,
            :flavor_id => options[:itype],
            :key_name => key_map[region],
            :username=>"ec2-user",
            :private_key_path=>"~/.ssh/#{key_map[region]}.pem",
            :security_group_ids=>secgroup.group_id,
            :availability_zone=>zone
          )

          server.wait_for { print "."; ready? }

          print "\nwaiting for sshd"
          server.wait_for { 
            print "."
              begin
              server.ssh 'whoami' 
              rescue
                print "#"
              end
          }

          # update it

          print "\nUpdating...waiting for result"

          result = server.ssh("sudo yum update -y;sudo gem update --no-ri --no-rdoc")
          
          if global_options[:verbose]
           # puts result.to_yaml
          end

          ### sync filesystems

          print "\nwaiting for sync"

          server.wait_for { 
            print "."
              begin
              server.ssh 'sync;sync' 
              rescue
                print "#"
              end
          }

          # snapshot the image

          root_vol_id = server.block_device_mapping[0]["volumeId"]

          ami_name = ami_tag + "-" + DateTime.now.strftime("%Y%m%d%H%M")

          print "\nSnapshotting vol #{root_vol_id} to #{ami_name}"

          snap = aws.snapshots.create(
            :name => ami_name,
            :desc => ami_name,
            :volume_id => root_vol_id
            )

          print "\nwaiting for snapshot.."
          snap.wait_for { print "."; ready? }

          new_block_map = [
              {
                "DeviceName" => "/dev/sda", 
                "SnapshotId" => snap.id, 
                "VolumeSize"=> snap.volume_size, 
                "DeleteOnTermination" => true
              }
          ]

            # register new ami

          aki = aws.images.all(
              "owner-alias" => "amazon",
              "image-type" => "kernel",
              "architecture" => "x86_64",
              "manifest-location" => "ec2-public-images-#{zone_map[region][:zone_base]}/pv-grub-hd0_*"
              ).last

          raise("\nNo kernel found") if aki == nil

          print "\negistering new ami.."

          new_ami = aws.register_image(
              ami_name,
              ami_name,
              "/dev/sda1",
              new_block_map,
              {
                "KernelId" => aki.id,
                "Architecture" => "x86_64"
              }
          )

          print "\nwaiting for ami to register..."

          new_ami = aws.images.all("image-id" => new_ami.body["imageId"]).last
          new_ami.wait_for { print "."; ready? }    

          print "\n"

          # delete tag from old image

          old_ami = aws.images.all("tag:Name"=>ami_tag.to_s,"owner-id"=>account_id.to_s).first

          if old_ami != nil
            tags = aws.tags.all("resource-id"=>old_ami.id) 

            tags.each do |t|
              if t.key == "Name"
                t.destroy
              end
            end
          end

          # tag new one

          aws.tags.create(:resource_id => new_ami.id, :key => "Name", :value => ami_tag)

          server.destroy  ## delete the boot server

          if old_ami != nil ## delete the old image        
            print "deregistering image #{old_ami.id}\n"
            aws.deregister_image(old_ami.id)  
            print "waiting for deregister...."
            sleep 10

            snap = aws.snapshots.get(old_ami.block_device_mapping[0]["snapshotId"])

            if snap != nil
              print "deleteing snapshot #{snap.id}\n"
              snap.destroy
            else
              print "WARNING: snapshot #{snap.id} not found!\n"
            end
          end

          root_ami = new_ami.id
        end
      end    
    end
  end
end

##################################################################################################

exclude_db_list = [
  {"Database"=>"information_schema"},
  {"Database"=>"innodb"},
  {"Database"=>"mysql"},
  {"Database"=>"performance_schema"},
  {"Database"=>"tmp"}
]

dbl = "dbuser_goes_here"
dbp = "dbpassword_goes_here"

desc 'Dump or Load database(s) in the specified ex environment, or clone database(s) between environments'
arg_name 'source_env [database name]'

command [:database,:db] do |c| 
  c.desc 'input/output file suffix (only applies to --all)'
  c.default_value "dbdump"
  c.flag [:suffix,:s]

  c.desc 'dump/load/clone all databases'
  c.switch [:all,:a]

  c.desc 'drop/create database first'
  c.switch [:create]

  c.desc "dump environment database(s)"
  c.arg_name 'source_env [db1name,db2name,...]'

  c.command :dump do |dump|
    dump.desc 'output file directory'
    dump.default_value "."
    dump.flag [:outputdir,:o]

    dump.action do |global_options,options,args|
      if options[:a]
        if args.length != 1 || !(args[0] == 'development' || args[0] == 'staging' || args[0] == 'production')
          raise "Invalid argument - wanted an env name"
        end
      
        client = Mysql2::Client.new(:host => "#{args[0]}", :username => dbl, :password => dbp)
        r = client.query("show databases")
        client.close
      
        dblist = r.select { |x| !exclude_db_list.member? x }
      else
        if args.length != 2 || !(args[0] == 'development' || args[0] == 'staging' || args[0] == 'production')
          raise "Invalid argument - wanted an env name and a db name"
        end
      
        dblist = [{"Database"=>args[1]}]
      end
    
      Dir.mkdir(options[:o]) if (!Dir.exist?(options[:o]) && !global_options[:p])
   
      dbstr = "appdb.#{args[0]}.nuku.net"
      
      dblist.each do |d|
        outfile = "#{options[:o]}/#{d["Database"]}.#{options[:s]}"
      
        print "dumping #{args[0]} #{d["Database"]} to #{outfile}\n" if global_options[:v]
      
        cmdstr = "mysqldump --opt -u #{dbl} --password=#{dbp} -h #{dbstr} #{d['Database']} > #{outfile}"
      
        print cmdstr+"\n" if (global_options[:v] || global_options[:p])
      
        `#{cmdstr}` if !global_options[:p]
      end
    
    end #dump action
    
  end # command dump
  
  c.desc 'load environment database(s)'
  c.arg_name 'destination_env [database dumpfile name]'

  c.command :load do |load|

    load.desc 'input file directory (only applies to --all)'
    load.default_value "."
    load.flag [:inputdir,:i]

    load.action do |global_options,options,args|
      if options[:a]
        if args.length != 1 || !(args[0] == 'development' || args[0] == 'staging' || args[0] == 'production')
          raise "Invalid argument - wanted an env name"
        end

        dblist = Dir["#{options[:i]}/*.#{options[:s]}"]
      else
        if args.length != 2 || !(args[0] == 'development' || args[0] == 'staging' || args[0] == 'production')
          raise "Invalid argument - wanted an env name and a db dump file name (or --all)"
        end

        dblist = ["#{args[1]}"]
      end

      dbstr = "appdb.#{args[0]}.nuku.net"

      dblist.each do |d|

        file = File.open(d)
        dbname = ""

        begin
          l = file.readline.split
          i = l.index "Database:"

          if i != nil
            dbname = l[i+1]
          end
        end until dbname != ""

        if options[:create]  
          print "drop/create #{args[0]} #{dbname}\n"  if (global_options[:v] || global_options[:p])

          if !global_options[:p]
            client = Mysql2::Client.new(:host => "appdb.#{args[0]}.nuku.net", :username => dbl, :password => dbp)
            begin
              r = client.query("drop database #{dbname}")
            rescue 
              puts "DB #{dbname} did not exist." if global_options[:v]
            end
            r = client.query("create database #{dbname}")
            client.close
          end
        end   

        print "loading #{args[0]} #{dbname} from #{d}\n"  if global_options[:v]

        cmdstr = "mysql -u #{dbl} --password=#{dbp} -h #{dbstr} #{dbname} < #{d}"

        print cmdstr+"\n" if (global_options[:v] || global_options[:p])

        `#{cmdstr}` if !global_options[:p]

      end

    end

  end # load
  
  c.desc 'Clone database(s) between environments'
  c.arg_name 'source_env destination_env [db1name,...dbXname]'

  c.command :clone do |clone|

    clone.action do |global_options,options,args|
      if options[:a]
        if args.length != 2
          raise "Invalid args, looking for src_env, dst_env"
        end
        client = Mysql2::Client.new(:host => "appdb.#{args[0]}.nuku.net", :username => dbl, :password => dbp)
        r = client.query("show databases")
        client.close

        dblist = r.select { |x| !exclude_db_list.member? x }
      else
        if args.length < 3
          raise "Invalid args, looking for src_env  dst_env and at least one database name (or --all)"
        end
        i = 2
        dblist = []
        while i < args.length
          dblist << {"Database"=>args[i]} 
          i += 1
        end
      end

      Dir.mkdir("/tmp/dump") if !Dir.exist?("/tmp/dump")

      dbstrout= "appdb.#{args[0]}.nuku.net"
      dbstrin = "appdb.#{args[1]}.nuku.net"

      dblist.each do |d|
        outfile = "/tmp/dump/#{d["Database"]}.dbdump"

        print "dumping #{args[0]} #{d["Database"]} to #{outfile}\n" if global_options[:v]

        cmdstr = "mysqldump --opt -u #{dbl} --password=#{dbp} -h #{dbstrout} #{d['Database']} > #{outfile}"

        print cmdstr+"\n" if (global_options[:v] || global_options[:p])
        print "Then reload #{outfile} into #{d["Database"]} on #{dbstrin}\n" if global_options[:p]

        `#{cmdstr}` if !global_options[:p]

        if !global_options[:p]
          file = File.open(outfile)
          dbname = ""

          begin
            l = file.readline.split
            i = l.index "Database:"

            if i != nil
              dbname = l[i+1]
            end
          end until dbname != ""

          if options[:create]  
            print "drop/create #{args[0]} #{dbname}\n"  if (global_options[:v])

            if !global_options[:p]
              client = Mysql2::Client.new(:host => dbstrin, :username => dbl, :password => dbp)
              begin
                r = client.query("drop database #{dbname}")
              rescue 
                puts "DB #{dbname} did not exist." if global_options[:v]
              end
              r = client.query("create database #{dbname}")
              client.close
            end
          end   

          print "loading #{args[1]} #{dbname} from #{outfile}\n"  if global_options[:v]

          cmdstr = "mysql -u #{dbl} --password=#{dbp} -h #{dbstrin} #{dbname} < #{outfile}"

          print cmdstr+"\n" if (global_options[:v] || global_options[:p])

          `#{cmdstr}` if !global_options[:p]
        end

      end

    end

  end  #clone

end

############################################################################################
# list servers by env
############################################################################################

desc 'list servers tagged with the specified value'
arg_name 'tag_value'

command [:list,:ls] do |c| 
  c.desc 'list all running servers'
  c.switch [:all,:a]

  c.desc 'tag name'
  c.default_value 'System'
  c.flag [:tag,:t]
  
  filters = Hash.new
  filters['owner-id'] = account_id
  filters['instance-state-name'] = "running"
  
  c.action do |global_options,options,args|
    if !options[:a]
      raise("Tag value required") if args.length != 1

      tagstr = "tag:#{options[:t]}"
      filters[tagstr] = args[0]
    end
    
    #servers = aws.servers.all(filterStr)
    pp filters
    servers = aws.servers.all(filters)
    
    servers.each do |s|
      pp s.public_ip_address
    end
    
  end

end

#######################################################

pre do |global,command,options,args|
  # Pre logic here
  # Return true to proceed; false to abourt and not call the
  # chosen command
  # Use skips_pre before a command to skip this block
  # on that command only
    # create a connection

    begin
      keystring = File.read global[:keyfile]
    rescue
      STDERR.puts "Error reading aws cred file #{global[:keyfile]}"
      return false
    end

    key = ""
    secret = ""

    keystring.split.each do |e|
      case e.split("=")[0]
      when "AWSAccessKeyId"
        key = e.split("=")[1]
      when "AWSSecretKey"
        secret = e.split("=")[1]
      end
    end

    aws = Fog::Compute.new({
      :provider                 => 'AWS',
      :aws_access_key_id        => key,
      :aws_secret_access_key    => secret,
      :region => zone_map[global[:region].to_sym][:zone_base]
    })
    
    elb = Fog::AWS::ELB.new({
      :aws_access_key_id        => key,
      :aws_secret_access_key    => secret,
      :region => zone_map[global[:region].to_sym][:zone_base]
    })

  #  dns = Fog::DNS.new({
  #    :provider=>'AWS', 
  #    :aws_access_key_id        => key,
  #    :aws_secret_access_key    => secret
  #  })
  #
  #  rds = Fog::AWS::RDS.new({
  #    :aws_access_key_id        => key,
  #    :aws_secret_access_key    => secret,  
  #    :region => zone_map[global[:region].to_sym][:zone_base]
  #  })


    true
  
end

post do |global,command,options,args|
  # Post logic here
  # Use skips_post before a command to skip this
  # block on that command only
end

on_error do |exception|
  # Error logic here
  # return false to skip default error handling
  #puts "ERROR TRAP"
  #pp exception
  true
end

exit run(ARGV)
