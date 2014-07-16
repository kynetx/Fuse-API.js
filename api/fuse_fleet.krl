ruleset fuse_fleet {
    meta {
        name "Functionality for Fleet Pico"
        description <<
Application that manages the fleet
        >>
        author "PJW from AKO GTour code"



        errors to b16x13

        use module a169x625  alias CloudOS
        use module a169x676  alias pds
	use module b16x19 alias common
	use module b16x11 alias carvoyant
	use module b16x23 alias carvoyant_oauth

        sharing on
        provides vehicleChannels, seeFleetData, vehicleSummary, vehicleStatus
    }

    global {

      // this is complicated cause we want to return the subscription channel for the vehicle, not the _LOGIN channel
      vehicleChannels = function() {

         common:vehicleChannels();
      };

      seeFleetData = function(){
        ent:fleet
      };

      vehicleSummary = function() {

        picos = CloudOS:picoList()|| {}; // tolerate lookup failures
        picos_by_id = picos.values().collect(function(x){x{"id"}}).map(function(k,v){v.head()});
	pico_ids = picos_by_id.keys();
 
	// get the subscription IDs (we don't want to use the Pico channels here...)
        vehicle_ecis = CloudOS:subscriptionList(common:namespace(),"Vehicle")
                    || [];   

        // collect returns arrays as values, and we only have one, so map head()
        vehicle_ecis_by_name = vehicle_ecis.collect(function(x){x{"channelName"}}).map(function(k,v){v.head()}).klog(">>> ecis by name  >>> ");


	summaries = ent:fleet{["vehicle_info"]}
		     .map(function(k,v){v.put(["picoId"], k).put(["channel"], vehicle_ecis_by_name{[k,"eventChannel"]}) });
	summary_keys = summaries.keys();



	// which picos exist that have no summary yet? 
	missing = pico_ids.difference(summary_keys).klog(">>>> missing vehicle data here >>>>");
	responses = missing.map(function(k){CloudOS:sendEvent(picos_by_id{[k,"channel"]}, "fuse", "need_vehicle_data", account_info)}); 
	
	summaries.values().klog(">>>> vehicle_info >>>>")

      };

      vehicleStatus = function() {
        ent:fleet{["vehicle_status"]}
      };

      findVehicleByBackchannel = function (bc) {
        garbage = bc.klog(">>>> back channel <<<<<");
        vehicle_ecis = CloudOS:subscriptionList(common:namespace(),"Vehicle");
	vehicle_ecis_by_backchannel = vehicle_ecis.collect(function(x){x{"backChannel"}}).map(function(k,v){v.head()});
	vehicle_ecis_by_backchannel{bc} || {}
      };

      findVehicleByName = function (name) {
        vehicle_ecis = CloudOS:subscriptionList(common:namespace(),"Vehicle");
	vehicle_ecis_by_name = vehicle_ecis
	                         .collect(function(x){x{"channelName"}})
				 .map(function(k,v){v.head()})
				 // .klog(">>>> vehicle ECIs by name")
				 ;
	vehicle_ecis_by_name{name} || {}
      };

    }

    // ---------- respond to owner ----------
    rule create_id_to_eci_mapping {
        select when fuse fleet_uninitialized

        {
            noop();
        }

        fired {
            set ent:idToECI {};
            set ent:inventory {};
        }
    }

    rule initialize_fleet_pico {
        select when fuse fleet_uninitialized

	pre {
	   fleet_name = event:attr("fleet_name");
           my_owner = event:attr("owner_channel");
           my_schema = event:attr("schema");

	}

        {
            noop();
        }

        fired {
	  // store meta info
	  raise pds event new_map_available 
            attributes 
              {"namespace": common:namespace(),
               "mapvalues": {"schema": my_schema,
	                     "owner_channel": my_owner,
			     "fleet_name": fleet_name
	                    },
               "_api": "sky"
              };

	  // set my schema
	  raise pds event new_data_available 
            attributes
              {"namespace": "myCloud",
               "keyvalue": "mySchemaName",
	       "value": my_schema,
	       "_api": "sky"
              };

          // set my cloudType
	  raise pds event new_settings_attribute 
            attributes
	      {"setRID"   : "a169x695",
  	       "setAttr"  : "myCloudType",
	       "setValue" : "cloudTypeThing",
	       "_api": "sky"
              };
	     
          // initialize my profile
	  raise pds event new_profile_item_available 
            attributes
	      {"myProfileName"  : fleet_name,
	       "myProfilePhoto" : common:fleet_photo,
	       "_api": "sky"
	      };

	  raise fuse event new_fleet 
            attributes
	      {"fleet_name": fleet_name,
	       "_api": "sky"
	      };
        }
    }

    // meant to generally route events to owner. Extend eventex to choose what gets routed
    rule route_to_owner {
      select when fuse new_fleet
               or fuse reminders_ready
	       or fuse email_for_owner
      pre {
        owner = CloudOS:subscriptionList(common:namespace(),"FleetOwner").head().pick("$.eventChannel");
      }
      {
        send_directive("Routing to owner")
          with channel = owner 
           and attrs = event:attrs();
        event:send({"cid": owner}, "fuse", event:type())
          with attrs = event:attrs();
      }
    }

    rule auto_approve_pending_subscriptions {
        select when cloudos subscriptionRequestPending
           namespace re/fuse-meta/gi

	pre {
	  fleet_channel = event:attr("eventChannel");
	}

        {
            noop();
        }

        fired {
            raise cloudos event subscriptionRequestApproved
                with eventChannel = fleet_channel
                and  _api = "sky";
        }
    }


    // ---------- manage vehicle picos ----------
    rule create_vehicle {
        select when fuse need_new_vehicle
        pre {
	  name = event:attr("name") || "Vehicle-"+math:random(99999);
          pico = common:factory({"schema": "Vehicle", "role": "vehicle"}, meta:eci());
          channel = pico{"authChannel"};
          vehicle = {
            "cid": channel
          };
	  pico_id = "Fleet-vehicle"+ random:uuid();
        }
	if (pico{"authChannel"} neq "none") then
        {

	  // depend on this directive name and id
	  send_directive("vehicle_created") with
            cid = channel and
	    id = pico_id;

          // tell the vehicle pico to take care of the rest of the initialization.
          event:send(vehicle, "fuse", "new_vehicle") with 
            attrs = (event:attrs()).put({"fleet_channel": meta:eci(),
             	    			 "schema":  "Vehicle",
	             			 "_async": 0    // we want this to be complete before we try to subscribe below
		    			});

        } 

        fired {

	  // make it a "pico" in CloudOS eyes
	  raise cloudos event picoAttrsSet
            with picoChannel = channel
             and picoName = name
             and picoPhoto = event:attr("photo")
             and picoId = pico_id
             and _api = "sky";

	  // subscribe to the new vehicle
          raise cloudos event "subscribe"
            with namespace = common:namespace()
             and  relationship = "Vehicle-Fleet"
             and  channelName = pico_id
             and  targetChannel = channel
             and  _api = "sky";

          log ">>> VEHICLE CHANNEL <<<<";
          log "Pico created for vehicle: " + pico.encode();

        } else {
          log ">>> VEHICLE CHANNEL <<<<";
          log "Pico NOT CREATED for vehicle " + name;
	}
    }

    rule show_vehicles {
      select when fuse show_vehicles
      pre {
        myPicos = CloudOS:picoList();
        fuseSubs = CloudOS:subscriptionList(common:namespace(),"Vehicle");
      }
      {
        send_directive("Dependent children") with
          children = myPicos and
	  just_fuse = fuseSubs;   

      }
      
    }

    // this is too general for this ruleset except for identifying subscriptions
    // FIXME: this doesn't (yet) delete the vehicle data from the fleet entity variable
    rule delete_vehicle {
      select when fuse delete_vehicle
      pre {
        name = event:attr("vehicle_name").klog(">>>>> deleting vehicle >>>> ");

	// use the eci to look up the subscription to delete
        this_sub = CloudOS:subscriptionList(common:namespace(),"Vehicle")
	           .filter(function(sub){sub{"channelName"} eq name})
		   .head()
		   .klog(">>>>>>> this_sub >>>>>>")
                || {};   // tolerate lookup failures

	// not sure why we want the sub???


	this_pico = common:find_pico_by_id(name).klog(">>>>>>>>>>> pico <<<<<<<<<<<<<<<") || {};

	something_to_do = not this_pico{"channel"}.isnull();

	this_pico_id = this_sub{"channelName"};

        this_sub_channel = this_sub{"backChannel"};
	sub_eci = this_sub{"eventChannel"}.klog(">>>>>> eci to destroy >>>>>");
	pico_eci = this_pico{"channel"}.klog(">>>>>> eci to destroy >>>>>");
	huh = (something_to_do) => CloudOS:cloudDestroy(sub_eci).klog(">>>> report from cloudDestroy >>> ") ||
	                               CloudOS:cloudDestroy(pico_eci).klog(">>>> report from cloudDestroy >>> ") 
                                 | 0;
      }
      if (something_to_do) then
      {
        send_directive("Deleted vehicle" ) with
          child = eci and
	  id = this_pico_id and
//          allSubs = CloudOS:subscriptionList(common:namespace(),"Vehicle") and
          fuseSub = this_sub and
          channel = this_sub_channel;
      }
      fired {

        // not a pico I'm keeping track of anymore      
        raise cloudos event picoAttrsClear 
          with picoChannel = this_pico{"channel"}
           and _api = "sky";

	raise cloudos event unsubscribe
          with backChannel = this_sub_channel
           and _api = "sky" if not this_sub_channel.isnull();

	clear ent:fleet{["vehicle_info", name]};

      } else {
        log ">>>>>> no vehicle to delete with name " + name;
	clear ent:fleet{["vehicle_info", name]};
      }
      
    }

    rule clear_out_pico is inactive {  // dangerous...
      select when maintenance clear_out_pico
      pre {
        picos = CloudOS:picoList();
	eci = picos.keys().head(); // clear the first one
      }	   
      send_directive("Clearing pico #{eci}") ;
      always {

        // not a pico I'm keeping track of anymore      
        raise cloudos event picoAttrsClear 
          with picoChannel = eci  // created with _LOGIN, not subscriber ECI, so look it up
           and _api = "sky";
      }

    }

    rule find_fuse_carvoyant_diffs {
      select when fuse fleet_updated
      pre {
        cv_vehicles = carvoyant:carvoyantVehicleData(); //.klog(">>>>> carvoyant vehicle data >>>>");
	my_vehicles = vehicleSummary().klog(">>>> Fuse vehicle data >>>>>");
	no_vehicle_id = my_vehicles.filter(function(v){v{"vehicleId"}.isnull()}).klog(">>>> no vid >>>>");
	by_vehicle_id = my_vehicles.filter(function(v){not v{"vehicleId"}.isnull()}).collect(function(v){v{"vehicleId"}}); //.klog(">>>> have vid >>>>"); 
	in_cv_not_fuse = 
	  cv_vehicles.filter(function(v){ by_vehicle_id{v{"vehicleId"}}.isnull() }); // .klog(">>> no matching fuse vehicle >>>> ");
      }
      {
        send_directive("sync_fleet") with
	  fuse_not_carvoyant = no_vehicle_id and
          carvoyant_not_fuse = in_cv_not_fuse
      }
      fired {
        log ">>>> syncing fleet and carvoyant>>> ";
        raise fuse event vehicles_not_in_carvoyant with
          vehicle_data = no_vehicle_id;

	 // raise fuse event vehicles_not_in_fuse with 
	 //   vehicle_data = in_cv_not_fuse

      }
    }

    // what do we want to do with these????
    rule sync_carvoyant_with_fuse {
      select when fuse vehicles_not_in_fuse
      foreach event:attr("vehicle_data") setting(vehicle)
        pre {
	  vid = vehicle{"vehicleId"}.klog(">>> Vehicle ID >>>>");
	  config_data = carvoyant:get_config(vid).klog(">>>>> config data >>>>>"); 
        }
	if(not vid.isnull()) then
	{
	  send_directive("Unclaimed Carvoyant Vehicles") with
	    vehicle_data = vehicle
	}
    }

    rule sync_fuse_with_carvoyant {
      select when fuse vehicles_not_in_carvoyant
      foreach event:attr("vehicle_data") setting(vehicle)
        pre {
	  pid = vehicle{"picoId"}.klog(">>> Pico ID >>>>");
	  vehicle_sub = findVehicleByName(pid);
	}
	if(not vehicle_sub{"eventChannel"}.isnull()) then
	{
	  send_directive("Initializing vehicle") with
	    vehicle_sub_info = vehicle_sub;
	  event:send({"cid": vehicle_sub{"eventChannel"}}, "carvoyant", "init_vehicle");
	}
	fired {
	  log ">>>> telling #{pid} to initialize itself with Carvoyant >>>"
	} else {
	  log ">>>> No event channel found for #{pid}"
	}
    }

    // ---------- cache vehicle data ----------

    rule update_vehicle_data_in_fleet {
      select when fuse updated_vehicle
      pre {
        vid = event:attr("vehicleId");
	keyvalue = event:attr("keyvalue");
        vehicle_info = event:attr("value").decode().klog(">>>> vehicle info >>>>>");

	// why am I gettting this?  Oh, yeah, we need to match vehicle_id and vehicle channel so we'll do that here...
	vehicle_channel_data = findVehicleByBackchannel(meta:eci());
	vehicle_name = vehicle_channel_data{"channelName"}.klog(">>>> vehicle name >>>> ");


      }
      {send_directive("Updated vehicle data for #{keyvalue} in fleet") with
         id = vid and
         values = vehicle_info and
	 keyvalue = keyvalue and
	 namespace = carvoyant_namespace and 
	 vehicle_name = vehicle_name
	 ;
      }

      always {
        set ent:fleet{[keyvalue, vehicle_name]} vehicle_info.put(["deviceId"], vid)
      }

    }

    rule clear_fleet_cache {
      select when fuse clear_fleet_cache
      always {
        clear ent:fleet
      }
    }


    // ---------- maintenance ----------
  rule find_due_reminders {
    // fire whenever we get new mileage
    select when fuse updated_vehicle_info

    pre {
      current_time = time:now();
      current_mileage = event:attr("mileage").klog(">>>> seeing this mileage >>>>> ");

      today = time:strftime(time:now(), "%Y%m%dT000000%z");

      days_since = daysBetween(time:now(), ent:last_reminder);
      

    }
    // once per day at most
    if( days_since > 1
      ) then {
      send_directive("Retrieving new reminders for today") with
	today = today and
	previous_day = ent:last_reminder;

      }

    fired {
      set ent:last_reminder today;
      raise fuse event reminders_finish;
    } else {
      log "Not enough days since last reminder: " + days_since;
    }

  }

  rule find_due_reminders_complete {
    select when fuse reminders_finish

    pre {
      all_subs = CloudOS:subscriptionList(common:namespace(),"Vehicle").pick("$.eventChannel").klog(">>> all_subs >>>>");
      createReminder = function(eci) {
        vinfo = ent:fleet{["vehicle_info", eci]};
        reminders = common:skyCloud(eci, "b16x21", "activeReminders", {"mileage": vinfo{"mileage"}, "current_time": time:now() });
	{"label": vinfo{"label"},
	 "photo": vinfo{"profilePhoto"},
	 "reminders": reminders
	}	
      };
      // flatten array of array
      reminders = all_subs.map(createReminder(eci)).klog(">>>>> all reminders >>>>>>>> ");
    }
    
    {
      send_directive("Seeing reminders") with
        reminders = reminders;
    }
    fired {
      raise fuse event reminders_ready with reminders = reminders;
    }

  }
  
  // ---------- fleet emails ----------
  rule send_fuse_periodic_report {
    select when fuse periodic_report
    pre {

      // configurables
      period = {"format": {"days" : -7}, // one week; must be negative
                "readable" : "weekly"
               };
      tz = "-0600"; 

      today = time:strftime(time:now(), "%Y%m%dT000000%z", {"tz":"UTC"});
      yesterday = time:add(today, {"days": -1});
      before = time:add(today, period{"format"});

      friendly_format = "%b %e";
      title = "Fuse Fleet Report for #{time:strftime(before, friendly_format)} to #{time:strftime(yesterday, friendly_format)}"; 
      subj = "Your "+period{"readable"}+" report from Fuse!";

      wrap_in_div = function(obj, class) {
        div = <<
<div class="#{class}">#{obj}</div>
>>;
	div
      };

      wrap_in_span = function(obj, class) {
        span = <<
<span class="#{class}">#{obj}</span>
>>;
	span
      };

      format_trip_line = function(trip) {
        cost = trip{"cost"}.isnull() || trip{"cost"} < 0.01 => ""
	     | "$" + trip{"cost"}.sprintf("%.2f");
        len = trip{"mileage"}.isnull() || trip{"mileage"} < 0.01 => ""
	    | trip{"mileage"} + " miles";
	name = trip{"name"}.isnull() || trip{"name"} eq "" => "none"
             | trip{"name"};
	time = trip{"endTime"}.isnull() => ""
	     | time:strftime(trip{"endTime"}, "%b %e %I:%M %p", {"tz": tz});

	duration_val = tripDuration(trip);
	duration = duration_val < 0.1 => ""
	         | wrap_in_span(duration_val.sprintf("%.01f") + " min", "trip_duration");
	
	odd_line_style = "font-family:Arial, sans-serif;font-size:14px;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#aaa;color:#333;background-color:#fff;";
	even_line_style = "font-family:Arial, sans-serif;font-size:14px;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#aaa;color:#333;background-color:#fff;background-color:#FCFBE3";

        line = <<
<tr>
<td style="#{odd_line_style}">#{time}</td>
<td style="#{odd_line_style}">#{name}</td>
<td style="#{odd_line_style}">#{len}</td>
<td style="#{odd_line_style}">#{cost}</td>
<td style="#{odd_line_style}">#{duration}</td>
</tr>
>>;
        line
      };

      tripDuration = function(trip) {
        (time:strftime(trip{"endTime"}, "%s") - time:strftime(trip{"startTime"}, "%s"))/60
      };

      aggregate_two_trips = function(a,b) {
        {"cost": a{"cost"} + b{"cost"},
	 "mileage" : a{"mileage"} + b{"mileage"},
	 "duration": a{"duration"} + tripDuration(b)
	}
      };

      format_vehicle_summary = function(vehicle) {
        name = vehicle{"profileName"};
        photo = vehicle{"profilePhoto"};
	address = vehicle{"address"} || "";
	gas = vehicle{"fuellevel"}.isnull() => ""
	    | "Fuel remaining: " + vehicle{"fuellevel"} + "%";
	    
	mileage = vehicle{"mileage"}.isnull() => ""
	        | "Odometer: " + vehicle{"mileage"};
	vin = vehicle{"vin"}.isnull() => "No VIN Recorded"
	    | "VIN: " + vehicle{"vin"};
        

	trips_raw = vehicle{"channel"}.isnull() => []
                  | common:skycloud(vehicle{"channel"},"b16x18","tripsByDate", {"start": before, "end": today}).klog(">>> skycloud return trips >>> ");
        trips = trips_raw.typeof() eq "hash" && trips_raw{"error"} => [].klog(">>> error for trips query to " + vehicle{"channel"})
              | trips_raw;  

        trips_html = trips.map(format_trip_line).join(" ");

	trip_aggregates = trips.reduce(aggregate_two_trips, {"cost":0,"mileage":0,"duration":0}).klog(">>>> aggregates>>>>");
	total_duration = trip_aggregates{"duration"}.sprintf("%.0f");	    
        total_miles = trip_aggregates{"mileage"}.sprintf("%.1f");
	total_cost = trip_aggregates{"cost"}.sprintf("%.2f"); 
	num_trips = trips.length(); 

	find_avg = function(x) {
          num_trips > 0 => x / num_trips
                         | 0;
	};

	avg_duration = find_avg(trip_aggregates{"duration"}).sprintf("%.0f");	    
        avg_miles = find_avg(trip_aggregates{"mileage"}).sprintf("%.1f");
	avg_cost = find_avg(trip_aggregates{"cost"}).sprintf("%.2f"); 

	longest = trips.reduce(function(a,b){
                    a{"mileage"} < b{"mileage"} => {"trip": b, "mileage": b{"mileage"}}
                                                 | a
	          }, {"trip": {}, "mileage": 0}).klog(">>>> longest >>>>");

	
	trip_table_header_style = "font-family:Arial, sans-serif;font-size:14px;font-weight:normal;padding:10px 5px;border-style:solid;border-width:1px;overflow:hidden;word-break:normal;border-color:#aaa;color:#fff;background-color:#f38630;";

	vehicle_table_row_style = "text-align=left;font-family:Arial, sans-serif;font-size:14px;padding:10px 5px;border-style:solid;border-width:0px;overflow:hidden;word-break:normal;";

        line = <<
<table width="100%" style="style="width:550px;border-collapse:collapse;border-spacing:0;">
<tr>
 <td style="width:120px;#{vehicle_table_header_style}">
  <img border="1" style="border:1px solid #e6e6e6;" src="#{photo}" align="left"/>
 </td>
 <td style="#{vehicle_table_header_style}">
  <h2>#{name}</h2>

  <div class="vehicle_address">#{address}</div>
  <div class="vehicle_vin">#{vin}</div>
  <div class="vehicle_mileage">#{mileage}</div>
  <div class="vehicle_fuellevel">#{gas}</div>
 </td>
</tr>
<tr style="">
 <td colspan="2" style="margin-top:50px;#{vehicle_table_header_style}">
  <h3>Trips from Last Week</h3>
 </td>
</tr>

<tr><td colspan="2" style="#{vehicle_table_header_style}"><b>#{name} took #{num_trips} trips: #{total_miles} miles, #{total_duration} min, $#{total_cost}</b></td></tr>
<tr><td colspan="2" style="#{vehicle_table_header_style}">Trip averages: #{avg_miles} miles, #{avg_duration} min, $#{avg_cost}</b></td></tr>

<tr><td colspan="2" style="#{vehicle_table_header_style}">
<table class="trip" style="width:545px;border-collapse:collapse;border-spacing:0;border-color:#aaa;">
<tr>
    <th colspan="5" style="text-align:center;#{trip_table_header_style}">#{name} Trips</th>
</tr>
<tr>
    <th style="#{trip_table_header_style}">Date</th>
    <th style="#{trip_table_header_style}">Name</th>
    <th style="#{trip_table_header_style}">Length</th>
    <th style="#{trip_table_header_style}">Cost</th>
    <th style="#{trip_table_header_style}">Duration</th>
  </tr>
#{trips_html}
</table>
</td></tr><!-- trips -->
</table><!-- vehicle -->
>>;
	line
      }; // format_vehicle_summary
      
      summaries = vehicleSummary();
      vehicle_html = summaries.map(format_vehicle_summary).join(" ");

      msg = <<
#{title}
>>;

      html = <<
<h2>#{title}</h2>

#{vehicle_html}

<div class="footer" style="text-align:center">
You are receiving this email because you have vehicles in Fuse. <br/>
<img align="center" src="https://s3.amazonaws.com/Fuse_assets/img/fuse_logo-30.png"/><br/>
&copy; Kynetx, Inc. 
</div>
>>;



      email_map = { "subj" :  subj,
		    "msg" : msg,
		    "html" : html
                  };


    }
    {
      send_directive("sending email to fleet owner") with
        content = email_map;
    }
    fired {
      raise fuse event email_for_owner attributes email_map.klog(">>>> sending with >>>>");
    }
    
  }

    
  // ---------- housekeeping rules ----------
  rule catch_complete {
    select when system send_complete
      foreach event:attr('send_results').pick("$.result") setting (result)
      send_directive("event:send status")
        with status = result{"status"}
	 and reason = result{"reason"}
	 and body = result{"body"}
	 ;
 }

// fuse_fleet.krl
}
