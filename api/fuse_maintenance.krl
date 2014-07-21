ruleset fuse_maintenance {
  meta {
    name "Fuse Maintenance App"
    description <<
Operations for maintenance
    >>
    author "PJW"
    sharing on

    errors to b16x13

    use module b16x10 alias fuse_keys

    use module a169x625 alias CloudOS
    use module a169x676 alias pds
    use module b16x19 alias common
    use module b16x11 alias carvoyant
    use module b16x9 alias vehicle

	
    provides activeReminders, 
             alerts, maintanceRecords, reminders

  }

 // reminder record
 // {<datetime> : { "timestamp" : <datetime>,
 // 	            "type" : mileage | date
 // 		    "id" : <datetime>,
 // 		    "what" : <string>,
 // 		    "mileage" : <string>,
 // 		    "due_date" : timestamp
 // 	          },
 //  ...
 // }
 // 
 // history record = reminder record + 
 //   "status" : complete | deferred 
 //   "updated" : <timestamp>
 //   "cost" : <string>
 //   "receipt" : <url>
 //   "vendor" : <string>


  global {

    // external decls

    activeReminders = function(current_time, mileage){
      utc_ct = common:convertToUTC(current_time);
      
      ent:reminders.query([], { 
       'requires' : '$or',
       'conditions' : [
          { 
     	   'search_key' : [ 'timestamp'],
       	   'operator' : '$lte',
       	   'value' : utc_ct 
	  },
     	  {
       	   'search_key' : [ 'mileage' ],
       	   'operator' : '$lte',
       	   'value' : mileage 
	  }
	]},
	"return_values"
	)
    };

    daysBetween = function(time_a, time_b) {
      sec_a = strftime(time_a, "%s");
      sec_b = strftime(time_b, "%s");
      math:abs(math:int((sec_a-sec_b)/86400));
    };

    alerts = function(id, limit, offset) {
       // x_id = id.klog(">>>> id >>>>>");
       // x_limit = limit.klog(">>>> limit >>>>>");
       // x_offset = offset.klog(">>>> offset >>>>>");

      id.isnull() => allAlerts(limit, offset)
                   | ent:alerts{id};
    };

    allAlerts = function(limit, offset) {
      sort_opt = {
        "path" : ["timestamp"],
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

      sorted_keys = this2that:transform(ent:alerts, sort_opt, global_opt).klog(">>> sorted keys for alerts >>>> ");
      sorted_keys.map(function(id){ ent:alerts{id} })
    };

    maintenanceRecords = function(id, limit, offset) {
       // x_id = id.klog(">>>> id >>>>>");
       // x_limit = limit.klog(">>>> limit >>>>>");
       // x_offset = offset.klog(">>>> offset >>>>>");

      id.isnull() => allMaintenanceRecords(limit, offset)
                   | ent:maintenance_records{id};
    };

    allMaintenanceRecords = function(limit, offset) {
      sort_opt = {
        "path" : ["timestamp"],
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

      sorted_keys = this2that:transform(ent:maintenance_records, sort_opt, global_opt).klog(">>> sorted keys for maintenance records >>>> ");
      sorted_keys.map(function(id){ ent:maintenance_records{id} })
    };

    reminders = function () { {} };

  }

  // ---------- alerts ----------
  rule record_alert {
    select when fuse new_alert
    pre {
      rec = event:attrs()
              .delete(["id"]) // new records can't have id
	      ; 
    }      
    {
      send_directive("Recording alert") with rec = rec
    }
    fired {
      raise fuse event updated_alert attributes rec; // Keeping it DRY
    }
  }

  rule update_alert {
    select when fuse updated_alert
    pre {

      // if no id, assume new record and create one
      new_record = event:attr("id").isnull();
      current_time = common:convertToUTC(time:now());

      id = event:attr("id") || random:uuid();

      reminder = reminder(event:attr("reminder_ref")) || {};

      activity = event:attr("activity") || reminder{"activity"};

      vdata = vehicle:vehicleSummary();

      odometer = event:attr("odometer") || vdata{"odometer"};

      rec = {
        "id": id,
	"trouble_codes": event:attr("trouble_codes"),
	"odometer": odometer,
	"reminder_ref": event:attr("reminder_ref") || "organic",
	"activity": activity,
	"timestamp": current_time
      };
    }
    if( not rec{"odometer"}.isnull() 
     && not rec{"activity"}.isnull()
     && not id.isnull()
      ) then
    {
      send_directive("Updating alert") with
        rec = rec
    }
    fired {
      log(">>>>>> Storing alert >>>>>> " + rec.encode());
      set ent:alerts{id} rec;
    } else {
      log(">>>>>> Could not store alert " + rec.encode());
    }
  }

  rule delete_alert {
    select when fuse unneeded_alert
    pre {
      id = event:attr("id");
    }
    if( not id.isnull() 
      ) then
    {
      send_directive("Deleting alert") with
        rec = rec
    }
    fired {
      clear ent:alerts{id} 
    }
  }

  rule process_alert {
    select when fuse maintenance_alert
    pre {
      id = event:attr("id");
      alert = alerts(id);
      status = event:attr("status");

      rec = {
        "alert_ref": id,
	"status": status,
	"agent": event:attr("agent"),
	"receipt": event:attr("receipt")
      };
    }
    if( not id.isnull()
     && not alert.isnull()
      ) then {
        send_directive("processing alert to create maintenance record") with 
	 rec = rec and
  	 alert = alert
      }
    fired {
      log ">>>> processing alert for maintenance  >>>> " + alert.encode();
      raise fuse event new_maintenance_record attributes rec
    } else {
    }
  }

  // ---------- maintenance_records ----------
  rule record_maintenance_record {
    select when fuse new_maintenance_record
    pre {
      rec = event:attrs()
              .delete(["id"]) // new records can't have id
	      ; 
    }      
    {
      send_directive("Recording maintenance_record") with rec = rec
    }
    fired {
      raise fuse event updated_maintenance_record attributes rec; // Keeping it DRY
    }
  }


  rule update_maintenance_record {
    select when fuse updated_maintenance_record
    pre {

      // if no id, assume new record and create one
      new_record = event:attr("id").isnull();
      current_time = common:convertToUTC(time:now());

      id = event:attr("id") || random:uuid();

      alert = alerts(event:attr("alert_ref")) || {};

      vdata = vehicle:vehicleSummary();

      status = event:attr("status") eq "completed" 
            || event:attr("status") eq "deferred" => event:attr("status")
             |                                       "unknown";

      activity = event:attr("activity") || alert{"activity"};
      odometer = event:attr("odometer") || vdata{"odometer"};

      completed_time = event:attr("timestamp") || current_time;

      rec = {
        "id": id,
	"activity": activity,
	"agent": event:attr("agent"),
	"status": status,
	"receipt": event:attr("receipt"),
	"odometer": odometer,
	"timestamp": completed_time
      };
    }
    if( not rec{"odometer"}.isnull() 
     && not rec{"activity"}.isnull()
     && not id.isnull()
      ) then
    {
      send_directive("Updating maintenance_record") with
        rec = rec
    }
    fired {
      log(">>>>>> Storing maintenance_record >>>>>> " + rec.encode());
      set ent:maintenance_records{id} rec;
    } else {
      log(">>>>>> Could not store maintenance_record " + rec.encode());
    }
  }

  rule delete_maintenance_record {
    select when fuse unneeded_maintenance_record
    pre {
      id = event:attr("id");
    }
    if( not id.isnull() 
      ) then
    {
      send_directive("Deleting maintenance_record") with
        rec = rec
    }
    fired {
      clear ent:maintenance_records{id} 
    }
  }



  // ---------- reminders ----------
  rule record_reminder {
    select when fuse new_reminder
    pre {
      rec = event:attrs()
              .delete(["id"]) // new records can't have id
	      ; 
    }      
    {
      send_directive("Recording reminder") with rec = rec
    }
    fired {
      raise fuse event updated_reminder attributes rec; // Keeping it DRY
    }
  }

  rule update_reminder {
    select when fuse updated_reminder
    pre {

      // if no id, assume new record and create one
      new_record = event:attr("id").isnull();
      current_time = common:convertToUTC(time:now());

      id = event:attr("id") || random:uuid();

      rec = {
        "id": id,
	"troubleCodes": event:attr("troubleCodes"),
	"odometer": event:attr("odometer"),
	"reminderRef": event:attr("reminderRef") || "organic",
	"activity": event:attr("activity"),
	"timestamp": current_time
      };
    }
    if( not rec{"odometer"}.isnull() 
     && not rec{"activity"}.isnull()
     && not id.isnull()
      ) then
    {
      send_directive("Updating reminder") with
        rec = rec
    }
    fired {
      log(">>>>>> Storing reminder >>>>>> " + rec.encode());
      set ent:reminders{id} rec;
    } else {
      log(">>>>>> Could not store reminder " + rec.encode());
    }
  }

  rule delete_reminder {
    select when fuse unneeded_reminder
    pre {
      id = event:attr("id");
    }
    if( not id.isnull() 
      ) then
    {
      send_directive("Deleting reminder") with
        rec = rec
    }
    fired {
      clear ent:reminders{id} 
    }
  }


  
  


}
