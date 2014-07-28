ruleset fuse_trips {
  meta {
    name "Fuse Manage Trips"
    description <<
Manage trips. PDS is not well-suited to these operations
    >>
    author "PJW"
    sharing on

    errors to b16x13

    use module b16x10 alias fuse_keys

    use module a169x625 alias CloudOS
//    use module a169x676 alias pds
    use module b16x19 alias common
    use module b16x11 alias carvoyant
    use module b16x9 alias vehicle
    use module b16x20 alias fuel

	
    provides trips, lastTrip, tripName, mileage, tripsByDate, newTrips,
             monthlyTripSummary,
             all_trips,   // for debugging
	       icalForVehicle, icalSubscriptionUrl
  }

  global {

    // external decls
    tripsByDate = function(start, end){

      utc_start = common:convertToUTC(start);
      utc_end = common:convertToUTC(end);
      
      sort_opt = {
        "path" : ["endTime"],
	"reverse": true,
	"compare" : "datetime"
      };

      this2that:transform(ent:trip_summaries.query([], { 
       'requires' : '$and',
       'conditions' : [
          { 
     	   'search_key' : [ 'endWaypoint', 'timestamp'],
       	   'operator' : '$gte',
       	   'value' : utc_start 
	  },
     	  {
       	   'search_key' : [ 'endWaypoint', 'timestamp' ],
       	   'operator' : '$lte',
       	   'value' : utc_end 
	  }
	]},
	"return_values"
	), 
       sort_opt)
    };


    trips = function(id, limit, offset) {
       x_id = id.klog(">>>> id >>>>>");
       // x_limit = limit.klog(">>>> limit >>>>>");
       // x_offset = offset.klog(">>>> offset >>>>>");

      id.isnull() => allTrips(limit, offset)
                   | ent:trips_by_id{mkTid(id)};
    };

    allTrips = function(limit, offset) {
      sort_opt = {
        "path" : ["endTime"],
	"reverse": true,
	"compare" : "datetime"
      };

      max_returned = 25;

      hard_offset = offset.isnull()     => 0               // default
                  |                        offset;

      hard_limit = limit.isnull()       => 10              // default
                 | limit > max_returned => max_returned
		 |                         limit;

      global_opt = {
        "index" : hard_offset,
	"limit" : hard_limit
      }; 

      sorted_keys = this2that:transform(ent:trip_summaries, sort_opt, global_opt.klog(">>>> transform using global options >>>> "));
      sorted_keys.map(function(id){ ent:trip_summaries{id} })
    };

    all_trips = function() {
      ent:trip_summaries
    };

    // temp for mark
    mileage = function(tid){
      ent:trip_summaries{[tid, "mileage"]}.klog(">>>>> trip mileage from summary");
    };

    lastTrip = function(with_data){
      with_data => ent:trips{ent:last_trip}
                 | ent:trip_summaries{ent:last_trip}.klog(">>> working with summary <<<")
    };

    tripName = function(start, end) {
      ent:trip_names{[reducePrecision(end), reducePrecision(start)]}
    }

    monthlyTripSummary = function(year, month) {
      ent:monthly_trip_summary{[year, month]}
    }

    waypointToArray = function(wp) {
      wp.typeof() eq "hash" => [wp{"latitude"}, wp{"longitude"}]
                             | wp.split(re/,/)
    };

    icalSubscriptionUrl = function() {
      ical_channel_name = "iCal_for_vehicle";
      channel_list = CloudOS:channelList();
      channels = channel_list{"channels"}.filter(function(x){x{"name"} eq ical_channel_name});
      channel = channels.length() > 0 => channels.head()
                		       | CloudOS:channelCreate(ical_channel_name);
      eci = channel{"cid"} || channel{"token"}; // CloudOS uses cid in one place and token in another 
      {"url": "webcal://" + meta:hostname() + "/sky/cloud/" + meta:rid() + "/icalForVehicle?_eci=" + eci }
    };

    icalForVehicleDoNothing = function(){""};

    // return cached copy unless new trip
    icalForVehicle = function(force){
      last_trip = lastTrip();
      last = time:strftime(last_trip{"endTime"}, "%s");
      ent:last_ical_time < last || force => generateIcalForVehicle()  
                                          | ent:last_ical    
    }


    generateIcalForVehicle = function(){
      sort_opt = {
        "path" : ["endTime"],
	"reverse": true,
	"compare" : "datetime"
      };
      global_opt = {
        "index" : 0,
	"limit" : 100 
      }; 
      
      t = this2that:transform(ent:trip_summaries, sort_opt, global_opt)
              .map(function(k) {
	        e = ent:trip_summaries{k};
	        start = e{["startWaypoint", "latitude"]} + "," + e{["startWaypoint", "longitude"]};
	        dest = e{["endWaypoint", "latitude"]} + "," + e{["endWaypoint", "longitude"]};
		miles = e{"mileage"} || "unknown";
	        url = "http://maps.google.com/maps?saddr="+ start + "&daddr=" + dest;
                cost_str = e{"cost"} => "Cost: $" + e{"cost"} | "";
		summary = e{"name"} neq "" => e{"name"} + " (" + miles + " miles)"
                                            | "Trip of " + miles + "miles"
	        {"dtstart" : e{"startTime"},
		 "dtend" : e{"endTime"},
		 "summary" : summary,
		 "url": url,
		 "description": "Trip ID: " + e{"id"} + "; " + cost_str,
		 "uid": "http://fuse.to/ical/v1/trip/" + $e{"id"}  // should be the same each time generated
		}
	      });
      vdata = vehicle:vehicleSummary();
      gen_time =  time:strftime(time:now(), "%s").pset(ent:last_ical_time); // save time generated
      ical:from_array(t, {"name": vdata{"label"}, 
                          "desc": "Calendar of trips for " + vdata{"label"}}
	             ).replace(re#\\;#g, ";").pset(ent:last_ical);
    };

    // find latlong within 365 feet
    reducePrecision = function(a) {
      a_array = waypointToArray(a);
      // 1 decimal place - 7 miles 
      // 2 decimal places - 0.7 miles 
      // 3 decimal places - 365 feet 
      // 4 decimal places - 37 feet 
      nearest = 1000; // 3 decimal places
      a_array.map(function(n){math:round(n * nearest)/nearest}).join(",");
    };


    // find if two points, a and b, are within radius distance in meters
    close = function(a, b, radius) {
      a_array = waypointToArray(a);
      b_array = waypointToArray(b);

      r90   = math:pi()/2;      
      rEm   = 6378100;         // radius of the Earth in meters
      rEf   = 20925524.9;      // radius of Earth in feet
  
      // convert co-ordinates to radians
      rlata = math:deg2rad(a_array[0]);
      rlnga = math:deg2rad(a_array[1]);
      rlatb = math:deg2rad(b_array[0]);
      rlngb = math:deg2rad(b_array[1]);
 
      // distance between two co-ordinates on earth in meters
      dE = math:great_circle_distance(rlnga, r90 - rlata, rlngb, r90 - rlatb, rEm);
      dE < radius
    };

    // internal decls
    endTime = function(trip) {
      trip{"endTime"} || 
      trip{["endWaypoint","timestamp"]} || 
      trip{["data"]}.head().pick("$..timestamp").head() || 
      "ERROR_NO_TIMESTAMP_AVAILABLE"
    };

    tripSummary = function(trip) {
       // summary =  {
       //   "startWaypoint" : trip{"startWaypoint"},
       //   "endWaypoint" : trip{"endWaypoint"},
       // 	"mileage": trip{"mileage"},
       // 	"id": trip{"id"},
       // 	"endTime": endTime(trip),
       // 	"startTime": trip{"startTime"}
       // };
      fillup = fuel:fillups() || {"mpg": 1, "unit_price": 0};
      mileage = trip{"mileage"} < 0.1 =>  0.0
                                       |  trip{"mileage"}.sprintf("%.2f");
      cost = math:round((mileage.klog(">>>> mileage <<<<<") / fillup{"mpg"}) * fillup{"unit_price"} * 1000) / 1000;

      interval = (time:strftime(trip{"endTime"}, "%s") - time:strftime(trip{"startTime"}, "%s"));
      
      avg_speed = mileage * 3600 / interval;
      
      summary = trip
                 .delete(["data"])
 		 .put(["cost"], cost.sprintf("%.2f"))
 		 .put(["interval"], interval.klog(">>>> trip length in seconds >>>>> "))
 		 .put(["avgSpeed"], avg_speed.sprintf("%.1f").klog(">>>> trip avg speed >>>>> "))
                ;
      summary
    };

    mkTid = function(tid){"T"+tid};
    mkCarvoyantTid = function(tid){tid.extract(re/T(\d+)/).head()};
  
  }

  rule clear_trip {
    select when fuse clear_trip
    always {
      clear ent:trips_by_id;
      clear ent:trip_summaries;
      clear ent:trips_by_week;
    }
  }

  // workhorse rule, saves and indexes trips and trip summaries
  rule save_trip {
    select when fuse new_trip
    pre {
      vid = carvoyant:vehicle_id();

      // accept either the trip as a set of attributes or just an ID that requires us to ping Carvoyant API
      incoming = event:attrs() || {};
      raw_trip_info = incoming{"mileage"}.isnull() => carvoyant:tripInfo(incoming{"tripId"}, vid)
                                                | incoming;
      tid = mkTid(raw_trip_info{"id"});
      end_time = endTime(raw_trip_info);

       // time_split = time:strftime(end_time, "%Y_:%m_:%d_:%H_:%M%S_").split(re/:/);
       // week_number = time:strftime(end_time, "%U_")

      trip_info = raw_trip_info.put(["endTime"], end_time).klog(">>>> storing trip <<<<< ");

      raw_trip_summary = tripSummary(trip_info);
      start =reducePrecision(raw_trip_summary{"startWaypoint"});
      end = reducePrecision(raw_trip_summary{"endWaypoint"});
      trip_name = tripName(start, end) || "";

      trip_summary = raw_trip_summary.put(["name"], trip_name);
      

    }
    if( end_time neq "ERROR_NO_TIMESTAMP_AVAILABLE" 
     && trip_info{"mileage"} > 0.01
      ) then
    {send_directive("Adding trip #{tid}") with 
      end_time = end_time and
      trip_summary = trip_summary
      ;
     event:send({"cid": vehicle:fleetChannel()}, "fuse", "updated_vehicle") with
         attrs = {"keyvalue": "last_trip_info",
	          "vehicleId": vid,
	          "value": trip_summary.encode()
		 }
    }
    fired {
      set ent:last_trip tid;
      set ent:trips_by_id{tid} trip_info;
      set ent:trip_summaries{tid} trip_summary;
      // set ent:trips_by_week{week_number} = (ent:trips_by_week{week_number} || []).append(tid);
      raise fuse event new_trip_saved with 
        tripId = tid
    } else {
      log ">>>>>>>>>>>>>>>>>>>>>>>>> save_trip failed <<<<<<<<<<<<<<<<<<<<<<<<<";
      log "End time: #{end_time}; mileage: " + trip_info{"mileage"};
    }
  }


  rule update_trip {
    select when fuse trip_meta_data
    pre {
      carvoyant_tid = event:attr("tripId");
      tid = mkTid(carvoyant_tid);
      tname = event:attr("tripName");
      tcategory = event:attr("tripCategory");
      trip_summary = trip_summaries{tid}.klog(">>>> trip summary for #{tid} >>>> ") || {};
      start =reducePrecision(trip_summary{"startWaypoint"});
      end = reducePrecision(trip_summary{"endWaypoint"});

    }
    if(not trip_summary{"startWaypoint"}.isnull()) then // if this isn't a real trip, don't pollute trip_summaries...
    {
      send_directive("Updating trip meta data") with
        tid = tid and
	trip_name = tname and
	trip_category = tcategory and
	start = start and
	end = end
    }
    fired {
      set ent:trip_summaries{tid} trip_summary
             .put(["category"], tcategory)
	     .put(["name"], tname);
      set ent:trip_names{[end, start]} {"tripName": tname}
    } else {
      log ">>> can't find #{tid} in trips for this vehicle >>>>> "
    }

  }

  rule name_trip {
    select when fuse trip_name
    pre {
      carvoyant_tid = event:attr("tripId");
      tid = mkTid(carvoyant_tid);
      tname = event:attr("tripName");	
      trip = ent:trip_summaries{tid} || {};
      start =reducePrecision(trip{"startWaypoint"});
      end = reducePrecision(trip{"endWaypoint"});
    }
//    if(not trip{"startWaypoint"}.isnull() && not trip{"endWaypoint"}.isnull()) then {
  {    send_directive("Named trip") with
        tripId = tid and
	anotherId = mkCarvoyantTid(tid) and
        tripName = tname and
	start = start and
	end = end and
	trip = trip
	;
	
    }
    fired {
      set ent:trip_names{[end, start]} {"tripId" : carvoyant_tid, "tripName": tname}
    } else {
      log "===========================================================================";
      log "Bad trip: " + trip.encode();
    }
  }

  rule update_vehicle_totals {
    select when fuse new_trip_saved
    pre {
      // do current month if no month given
      raw_month = event:attr("month") || time:now();
      month = time:strftime(raw_month, "%m");
      year = time:strftime(raw_month, "%Y");

      start = time:strftime(raw_month, "%Y%m01T000000%z");
      end = time:add(start, {"months": 1});
      month_totals = tripsByDate(start, end)
                      .reduce(function(a, b){ 
		                              // for some early trips for a few people. Kill later... [PJW]
                                              new_interval = (time:strftime(b{"endTime"}, "%s") - time:strftime(b{"startTime"}, "%s"));
	                                      {"cost": a{"cost"} + b{"cost"}, 
		                               "interval": a{"interval"} + new_interval.klog(">>> trip interval >>> "),
					       "mileage": a{"mileage"} + b{"mileage"},
					       "trip_count": a{"trip_count"} + 1
					      }
					    },
			      {"cost": 0, 
		               "interval": 0,
			       "mileage": 0,
			       "trip_count": 0
			      }
                             );

    }
    always {
      set ent:monthly_trip_summary{[year, month]} month_totals;
    }
  }

}
