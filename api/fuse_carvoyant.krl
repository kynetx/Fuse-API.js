ruleset fuse_carvoyant {
  meta {
    name "Fuse Carvoyant Ruleset"
    author "Phil Windley"
    description <<
Provides rules for handling Carvoyant events. Modified for the Mashery API
>>

    sharing on   // turn off after debugging

    use module b16x10 alias fuse_keys
      with foo = 1

    use module a169x625 alias CloudOS
    use module a169x676 alias pds
    use module b16x19 alias common
    use module b16x23 alias carvoyant_oauth

    errors to b16x13

    provides namespace, vehicle_id, get_config, carvoyant_headers, carvoyant_vehicle_data, get_vehicle_data, 
	     carvoyantVehicleData, isAuthorized, 
             vehicleStatus, keyToLabel, tripInfo, trips, dataSet,
             getSubscription, no_subscription, add_subscription, del_subscription, missingSubscriptions,
             get_eci_for_carvoyant

  }

  global {

    // [TODO] 
    //  vehicle ID can't be in config data. Has to match one of them, but is supplied

    data_labels = {
		  "GEN_DTC"          : "Diagnostic Trouble Codes" ,
		  "GEN_VOLTAGE"      : "Battery Voltage" ,
		  "GEN_TRIP_MILEAGE" : "Trip Mileage (last trip)" ,
		  "GEN_ODOMETER"     : "Vehicle Reported Odometer" ,
		  "GEN_WAYPOINT"     : "GPS Location" ,
		  "GEN_HEADING"      : "Heading" ,
		  "GEN_RPM"          : "Engine Speed" ,
		  "GEN_FUELLEVEL"    : "% Fuel Remaining" ,
		  "GEN_FUELRATE"     : "Rate of Fuel Consumption" ,
		  "GEN_ENGINE_COOLANT_TEMP" : "Engine Coolant Temperature" ,
		  "GEN_SPEED"        : "Maximum Speed Recorded (last trip)"
		};

    keyToLabel = function(key) {
      data_labels{key};
    };

    // appears in both this ruleset and fuse_fleet_oauth
    namespace = function() {
      "fuse:carvoyant";
    };

    vehicle_id = function() {
      config = pds:get_item(namespace(), "config") || {}; // can delete after vehicles are updated
      me = pds:get_me("deviceId"); 
      config{"deviceId"}
     ||
      me
     ||
      pds:get_item(namespace(), "vehicle_info").pick("$.vehicleId", true).head();
    };

    api_hostname = "api.carvoyant.com";
    apiHostname = function() {api_hostname};
    api_url = "https://"+api_hostname+"/v1/api";
    apiUrl = function() { api_url };


    // ---------- config ----------

    getTokensFromFleet = function() {
       my_fleet = CloudOS:subscriptionList(common:namespace(),"Fleet").head();
       (not my_fleet.isnull()) => common:skycloud(my_fleet{"eventChannel"},"b16x23","getTokens", {"id": my_fleet{"channelName"}})
                                | null
    }

    // if we're the fleet, we ask the module installed here, if not, ask the fleet
    getTokensAux = function() {
      my_type = pds:get_item("myCloud", "mySchemaName").klog(">>> my type >>>>");
      tokens = (my_type eq "Fleet") => carvoyant_oauth:getTokens()
                                     | getTokensFromFleet();
      tokens || {}
    };
    
    getTokens = function() {
      saved_tokens = (ent:token_cache || {}).klog(">>>> saved tokens >>>>> ");
      tokens = (saved_tokens{"txn_id"} eq meta:txnId().klog(">>>> my txn_id >>>> "))               &&
                not saved_tokens{"tokens"}.isnull()                   && 
		not saved_tokens{["tokens", "access_token"]}.isnull() => saved_tokens{"tokens"}.klog(">>>> using cached tokens >>>> ")
                                                                       | getTokensAux();
      // cache the tokens for this transaction only
      new_save = {"tokens": tokens,
                  "txn_id" : meta:txnId()
                 }.pset(ent:token_cache);
      tokens

    }

    // vehicle_id is optional if creating a new vehicle profile
    // key is optional, if missing, use default
    get_config = function(vid, key) {
       carvoyant_config_key = key || namespace();
       config_data = {"deviceId": vehicle_id() || "no device found"};
       base_url = api_url+ "/vehicle/";
       url = base_url + vid;
       account_info = getTokens() || {};
       access_token = (not account_info.isnull()) => account_info{"access_token"}
                                                   | "NOTOKEN"
       config_data
         .put({"hostname": api_hostname,
	       "base_url": url,
	       "access_token" : access_token		  
	      })
    }

    isAuthorized = function() {
      {"authorized" : carvoyant_oauth:validTokens() && tokensWork()}.klog(">>>> account authorized? >>>> ") 
    }
    
    tokensWork = function() {
      account_info = getTokens() || {};

      config_data = get_config();
      vehicle_info = expired => {} | carvoyant_get(api_url+"/vehicle/", config_data) || {};
      vehicle_info{"status_code"} eq "200"
    };



    // ---------- general carvoyant API access functions ----------
    // See http://confluence.carvoyant.com/display/PUBDEV/Authentication+Mechanism for details
    oauthHeader = function(access_token) {
      {"Authorization": "Bearer " + access_token.klog(">>>>>> using access token >>>>>>>"),
       "content-type": "application/json"
      }
    }

    // functions
    // params if optional
    carvoyant_get = function(url, config_data, params, redo) {
       config_data{"access_token"} neq "NOTOKEN" => carvoyant_get_aux(url, config_data, params, redo)
                                                  | null
    }   

    carvoyant_get_aux = function(url, config_data, params, redo) {
      raw_result = http:get(url, 
                            params, 
			    oauthHeader(config_data{"access_token"}),
			    ["WWW-Authenticate"]
			   );
      (raw_result{"status_code"} eq "200") => {"content" : raw_result{"content"}.decode(),
                                               "status_code": raw_result{"status_code"}
                                              } |
      (raw_result{"status_code"} eq "401") &&
      redo.isnull()                        => raw_result.klog(">>>>>>> carvoyant_get() token error >>>>>>")
                                            | raw_result.klog(">>>>>>> carvoyant_get() unknown error >>>>>>")
                   
                  
    };

    // actions
    carvoyant_post = defaction(url, payload, config_data) { // updated for Mashery
      configure using ar_label = false;

      // check and update access token???? How? 

      //post to carvoyant
      http:post(url) 
        with body = payload
	 and headers = oauthHeader(config_data{"access_token"})
         and autoraise = ar_label.klog(">>>>> autoraise label >>>>> ");
    };

    carvoyant_put = defaction(url, params, config_data) {
      configure using ar_label = false;
      http:put(url)
        with body = payload
	 and headers = oauthHeader(config_data{"access_token"})
         and autoraise = ar_label;
    };

    carvoyant_delete = defaction(url, config_data) {
      configure using ar_label = false;
      http:delete(url) 
        with headers = oauthHeader(config_data{"access_token"})
         and autoraise = ar_label; 
    };


    // ---------- vehicle data ----------
    // without vid, returns data on all vehicles in account
    carvoyant_vehicle_data = function(vid) {
      vid = vid || vehicle_id();
      config_data = get_config(vid);
      carvoyant_get(config_data{"base_url"}, config_data);
    };

    get_vehicle_data = function (vehicle_data, vehicle_number, dkey) {
      vda = vehicle_data{["content","vehicle"]} || [];
      vd = vehicle_number.isnull() => vda | vda[vehicle_number];
      dkey.isnull() => vd | vd{dkey}
    };

    carvoyantVehicleData = function(vid) {
      config_data = get_config(vid);
      data = carvoyant_get(config_data{"base_url"}, config_data).klog(">>> retrieved vehicle data >>>") || {};
      status = data{"status_code"} eq "200" => data{["content","vehicle"]}
             | vid.isnull()                 => [] // no vid expect array
             |                                 {} // vid expect hash
      status
    }

    vehicleStatus = function(vid) {
      vid = vid || vehicle_id();
      config_data = get_config(vid);
      most_recent = carvoyant_get(config_data{"base_url"}+"/data?mostRecentOnly=true", config_data);
      status = 
        most_recent{"status_code"} eq "200" => most_recent{["content","data"]}
         			       	     	  .collect(function(v){v{"key"}}) // turn array into map of arrays
 					          // get rid of arrays and replace with value plus label
                           		          .map(function(k,v){v[0].put(["label"],keyToLabel(k))})
                                             | mk_error(most_recent);
      status
    };


    // ---------- trips ----------
    // vid is optional
    tripInfo = function(tid, vid) {
      config_data = get_config( vid.defaultsTo( vehicle_id() ) ).klog(">>> Config data in tripInfo >>>>>");
      trip_url = config_data{"base_url"} + "/trip/#{tid}";
      result = carvoyant_get(trip_url, config_data); 
      result{"status_code"} eq "200" => result{["content","trip"]}
                                      | mk_error(result)
    }

    trips = function(start, end, vid) {
      config_data = get_config(vid).klog(">>> Config data in tripInfo >>>>>");
      trip_url = config_data{"base_url"} + "/trip/";
      params = {"startTime": start,
                "endTime": end
               };
      result = carvoyant_get(trip_url, config_data, params);
      result{"status_code"} eq "200" => result{["content","trip"]}
                                      | mk_error(result)
    }

    // ---------- data sets ----------
    dataSet = function(vid, sid) {
      config_data = get_config(vid).klog(">>> Config data in dataSet >>>>>");
      dataset_url = config_data{"base_url"} + "/dataSet/#{sid}";
      params = {};
      result = carvoyant_get(dataset_url, config_data, params);
      result{"status_code"} eq "200" => result{["content","dataSet", "datum"]}
                                      | mk_error(result)
    }
    

    mk_error = function(res) { // let's try the simple approach first
      res
    }

    // ---------- subscriptions ----------
    carvoyant_subscription_url = function(subscription_type, config_data, subscription_id) {
       base_url = config_data{"base_url"} + "/eventSubscription/" + subscription_type;
       subscription_id.isnull() => base_url 
	                         | base_url + "/" + subscription_id
    };

    valid_subscription_type = function(sub_type) {
      valid_types = {"geofence": true,
                     "lowbattery": true,
		     "numericdatakey": true,
		     "timeofday": true,
		     "troublecode": true,
		     "ignitionstatus": true,
		     "vehicledisconnected": true,
		     "vehicleconnected": true
      };
      not valid_types{sub_type.lc().klog(">>> looking for >>> ")}.isnull()
    }

    // check that the subscription list is empty or all in it have been deleted
    no_subscription = function(subs, key) {
        // a subscription doesn't exist if...
	   subs.length() == 0 
        ||
	   subs.none(function(s){ s{"postUrl"}.klog(">>>> key >>> ").match(re#/sky/event#) } )
	||
	  (  subs.all(function(s){ s{"_type"}.klog(">>> type >>>") eq "NUMERICDATAKEY" })
          && subs.none(function(s){ s{"dataKey"}.klog(">>>> key >>> ") eq key } )
          ) 
	||
	   subs.all(function(s){ not s{"deletionTimestamp"}.isnull() })	
    }

    // my_subs is optional, we'll get it if not supplied
    missingSubscriptions = function(req_subs, sub_map, my_subs) {
      current_subs = my_subs.isnull() =>  getSubscription(vehicle_id(), sub_type)
                                             .defaultsTo([], ">> no response on subscription call to Carvoyant >>")
                                             .klog(">>> seeing subscriptions >>>>")
                                        | my_subs
           		                ;

      
      req_sub_map = sub_map.filter(function(k,v) { req_subs.filter(function(x){x eq k}).length() > 0} )
                           .klog(">> required sub map >>")
			   ;
      
      found_subs = req_sub_map
                       .filter(function(k, sub) {
                                  current_subs.filter(
                                    function(cs) { 
                                      sub{"subscription_type"}.uc() eq cs{"_type"} &&
                                      (cs{"_type"} eq "NUMERICDATAKEY" => cs{"dataKey"} eq sub{"dataKey"}
                                                                        | true
                                      )
                                  }).length() > 0
                               })
                       .klog(">> found subs >> ")
                       ;
      req_subs.difference(found_subs.keys())  
    }

    // subscription functions
    // subscription_type is optional, if left off, retrieves all subscriptions for vehicle
    // subscription_id is optional, if left off, retrieves all subscriptions of given type
    getSubscription = function(vehicle_id, subscription_type, subscription_id) {
      config_data = get_config(vehicle_id);
      raw_result = carvoyant_get(carvoyant_subscription_url(subscription_type, config_data, subscription_id),
   	                         config_data);
      raw_result{"status_code"} eq 200 => raw_result{["content","subscriptions"]} |
      subscription_id.isnull()         => []
                                        | {}
    };


    // subscription actions
    add_subscription = defaction(vid, subscription_type, params, target) {
      configure using ar_label = false;
      config_data = get_config(vid);
      esl = mk_subscription_esl(subscription_type, target);
      // see http://confluence.carvoyant.com/display/PUBDEV/NotificationPeriod
      np = params{"notificationPeriod"} || "STATECHANGE";
      carvoyant_post(carvoyant_subscription_url(subscription_type, config_data),
      		     params.put({"postUrl": esl, "notificationPeriod": np}).klog(">>> subscription payload >>>"),
                     config_data
		    )
        with ar_label = ar_label;
    }; 

    del_subscription = defaction(subscription_type, subscription_id, vid) {
      configure using ar_label = false;
      config_data = get_config(vid);
      carvoyant_delete(carvoyant_subscription_url(subscription_type, config_data, subscription_id).klog(">>>>>> deleting with this URL >>>>> "),
                       config_data)
        with ar_label = ar_label;
    }

    // ---------- internal functions ----------
    // this should be in a library somewhere
    // eci is optional
    mk_subscription_esl = function(event_name, target) {
      use_eci = get_eci_for_carvoyant() || "NO_ECI_AVAILABLE"; 
      eid = math:random(99999);
      host = target || meta:host();
      "https://#{host}/sky/event/#{use_eci}/#{eid}/carvoyant/#{event_name}";
    };

    // creates a new ECI (once) for carvoyant
    get_eci_for_carvoyant = function() {
      carvoyant_channel_name = "carvoyant-channel";
      current_channels = CloudOS:channelList();
      carvoyant_channel = current_channels{"channels"}.filter(function(x){x{"name"} eq carvoyant_channel_name});
      carvoyant_channel.length() > 0 => carvoyant_channel.head().pick("$.cid")
                                      | CloudOS:channelCreate(carvoyant_channel_name).pick("$.token")
    }

    normalize_carvoyant_attributes = function(attrs) {
           attrs.defaultsTo({})	
                .put(["timestamp"], common:convertToUTC(time:now()))
       		.delete(["_generatedby"]);

    }

  }


   // // ---------- for retries from posting... ----------

   // rule retry_refresh_token {
   //   select when http post status_code re#401# label "???" // check error number and header...
   //   pre {
   //     tokens = carvoyant_oauth:refreshTokenForAccessToken(); // mutates ent:account_info
   //   }
   //   if( tokens{"error"}.isnull() ) then 
   //   {
   //     send_directive("Used refresh token to get new account token");
   //   }
   //   fired {
   //     raise carvoyant event new_tokens_available with tokens = getTokens() //ent:account_info
   //   } else {
   //     log(">>>>>>> couldn't use refresh token to get new access token <<<<<<<<");
   //     log(">>>>>>> we're screwed <<<<<<<<");
   //   }
   // }


  // ---------- rules for initializing and updating vehicle cloud ----------

  // creates and updates vehicles in the Carvoyant system
  rule carvoyant_init_vehicle {
    select when carvoyant init_vehicle
             or pds profile_updated vin re#^.+$#
    pre {
      foo = event:attrs().klog(">>>> did we see attributes? >>>>> ");
      cv_vehicles = carvoyantVehicleData().klog(">>>>> carvoyant vehicle data >>>>") ;
      profile = pds:get_all_me().klog(">>>>> profile >>>>>");
      vehicle_match_did = cv_vehicles
                        .filter(function(v){
			          v{"deviceId"} eq profile{"deviceId"}  
                               })
			.head() // should only be one
			;
      vehicle_match_vid = cv_vehicles
                        .filter(function(v){
			          v{"vehicleId"} eq ent:vehicle_data{"vehicleId"}
                               })
			.head() // should only be one
			;
      vehicle_match_vin = cv_vehicles
                        .filter(function(v){
			          v{"vin"} eq profile{"vin"}  
                               })
			.head() // might be more than one
			;

      vehicle_match = not vehicle_match_did.isnull() => vehicle_match_did.klog(">>>> matching vehicle by device Id >>>>") 
                    | not vehicle_match_vid.isnull() => vehicle_match_vid.klog(">>>> matching vehicle by vehicle Id >>>>")
                    |                                   vehicle_match_vin.klog(">>>> matching vehicle by VIN >>>>")
                    ;

      // true if vehicle exists in Carvoyant with same vin and not yet linked
      should_link = ( not vehicle_match.isnull()  // have a matching vehicle
                    ).klog(">>> should we link???? >>>>> ");


      foo = ent:vehicle_data{"vehicleId"}.klog(">>> stored vehicle ID >>>");

      vehicle_with_vid = cv_vehicles
                        .filter(function(v){
			          v{"vehicleId"} eq ent:vehicle_data{"vehicleId"}
                               })
			.head().klog(">>>> matching vehicle by VID >>>>");
      // true if the vid we have is not valid or we don't have one
      should_create = (vehicle_with_vid.isnull() || ent:vehicle_data{"vehicleId"}.isnull()).klog(">>> should we create???? >>>>> ");			       		

      vid = should_link    => vehicle_match{"vehicleId"} 
          | should_create  => "" // pass in empty vid to ensure we create one
          |                   ent:vehicle_data{"vehicleId"} || profile{"deviceId"};

      config_data = get_config(vid).klog(">>>>> config data >>>>>"); 
      params = {
        "name": event:attr("name") || profile{"myProfileName"} || "Unknown Vehicle",
        "deviceId": event:attr("deviceId") || profile{"deviceId"} || "",
        "label": event:attr("label") || profile{"myProfileName"} || "My Vehicle",
	"vin": event:attr("vin") || profile{"vin"} || "",
        "mileage": event:attr("mileage") || profile{"mileage"} || "10"
      }.klog(">>>> vehicle with these params >>>> ");

      carvoyant_url = config_data{"base_url"};

//      valid_tokens = carvoyant_oauth:validTokens().klog(">>>>> are tokens valid? >>>>>"); // can't do this only works in fleet
      valid_tokens =  not config_data{"access_token"}.isnull();

      valid_vin = vin.length() == 0 // empty is OK
	       || vin.match(re/^[A-HJ-NPR-Za-hj-npr-z0-9]{12}\d{5}$/) // 17 char long, alphanumeric w/o IOQ, last 5 digits
                ;
     
    }
    if( params{"deviceId"} neq "unknown"
     && valid_vin.klog(">>>> is vin valid? >>>> ")
     && valid_tokens.klog(">>>>> are tokens valid? >>>>> ")
      ) then
    {
      send_directive("Initializing or updating Carvoyant vehicle for Fuse vehicle ") with params = params;
      carvoyant_post(carvoyant_url,
      		     params,
                     config_data
   	    )
        with ar_label = "vehicle_init";
    }
    fired { 
      log(">>>>>>>>>> initializing Carvoyant account with device ID = " + params{"deviceId"});
      set ent:last_carvoyant_url carvoyant_url;
      set ent:last_carvoyant_params params.encode();
      // don't want to do this on error do we? 
      raise fuse event vehicle_uninitialized if should_link || event:name() eq "init_vehicle";
    } else {
      log(">>>>>>>>>> Carvoyant account initializaiton failed; missing device ID");
    }
  }

 
  rule initialization_ok { 
    select when http post status_code  re#2\d\d#  label "vehicle_init" 
    pre {

      // not sure this is actually set with the new data. If not, make a call to get()
      vehicle_data = event:attr('content').decode().pick("$.vehicle");

      storable_vehicle_data = vehicle_data;

      label = event:attr("label");

       // .filter(function(k,v){k eq "name" || 
       // 			      					k eq "vehicleId" ||
       // 								k eq "deviceId" ||
       // 								k eq "vin" ||
       // 								k eq "label" ||
       // 								k eq "mileage"
       //                                                          })
    }
    {
       event:send({"eci": owner}, "fuse", "vehicle_error") with
          error_type = label and
	  set_error = false
          ;

    }
    always {
      raise fuse event subscription_check;
      set ent:vehicle_data storable_vehicle_data;
      raise fuse event "vehicle_account_updated" with 
        vehicle_data = vehicle_data;
      raise pds event updated_data_available
	  attributes {
	    "namespace": namespace(),
	    "keyvalue": "vehicle_info",
	    "value": {"vehicleId": vehicle_data{"vehicleId"},
		      "year" :  vehicle_data{"year"},
		      "make" :  vehicle_data{"make"},
	              "model" : vehicle_data{"model"}
	             },
            "_api": "sky"
 		   
	  };
      raise carvoyant event new_device_id 
        with deviceId = "BAD DEVICE ID" if deviceId.isnull()
    }
  }

  rule vehicle_delete {
    select when carvoyant vehicle_not_needed
    pre {
      vid = event:attr("vid");
      config_data = get_config(vid);
    }
    if ( not vid.isnull() ) then
    {
      carvoyant_delete(config_data{"base_url"}, config_data) with
	  ar_label = "vehicle_deleted";
      send_directive("Deleting subscription") with attributes = event:attrs();
    }
    fired {
      log "Deleting Carvoyant vehicle #{vid}"
    } else {
      log "Cannot delete vehicle in Carvoyant; no vehicle ID"
    }
  } 
  

  // ---------- rules for managing subscriptions ----------
  rule carvoyant_add_subscription {
    select when carvoyant new_subscription_needed
    pre {
      vid = event:attr("vehicle_id") || vehicle_id();
      sub_type = event:attr("subscription_type");

      default_sub_target = meta:rid().klog(">>>> this rid >>>>")
                                     .match(re/b16x11/) => "kibdev.kobj.net"
                                                         | "cs.kobj.net";


      sub_target = event:attr("event_host").defaultsTo(default_sub_target);
      
      minimumTime = event:attr("minimumTime").defaultsTo("0", ">>> using default min time>>>");

      params = event:attrs()
                  .delete(["vehicle_id"])
                  .delete(["idempotent"])
                  .delete(["event_host"])
		  .put(["minimumTime"], minimumTime)
		  .klog(">>> using these parameters >>>>")
                  ;
      // if idempotent attribute is set, then check to make sure no subscription of this type exist
      subs = getSubscription(vid, sub_type).klog(">>> seeing subscriptions for #{vid} >>>>");
      subscribe = not event:attr("idempotent") ||
                  no_subscription(subs, params{"dataKey"})
    }
    if( valid_subscription_type(sub_type)  
     && subscribe
     && vid
      ) then {
        add_subscription(vid, sub_type, params, sub_target) with
    	  ar_label = "add_subscription";
        send_directive("Adding subscription") with
	  attributes = event:attrs();
    }
    notfired {
      error info "Invalid Carvoyant subscription type: #{sub_type}" if (not valid_subscription_type(sub_type));
      log  "Already subscribed; saw " + subs.encode() if valid_subscription_type(sub_type);
    }
  }

  rule subscription_ok {
    select when http post status_code re#(2\d\d)# label "add_subscription" setting (status)
    pre {
      sub = event:attr('content').decode().pick("$.subscription");
     // new_subs = ent:subscriptions.put([sub{"id"}], sub);  // FIX
    }
    send_directive("Subscription added") with
      subscription = sub
     // always {
     //   set ent:subscriptions new_subs
     // }
  }


  rule subscription_delete {
    select when carvoyant subscription_not_needed
    pre {
      sub_type =  event:attr("subscription_type");
      id = event:attr("id");
    }
    if valid_subscription_type(sub_type) then
    {
      del_subscription(sub_type, id, vehicle_id())
        with ar_label = "subscription_deleted";
      send_directive("Deleting subscription") with attributes = event:attrs();
    }
    notfired {
      error info "Invalid Carvoyant subscription type: #{sub_type} for #{id}";
    }
  }   

  rule subscription_show {
    select when carvoyant need_vehicle_subscriptions
    pre {
      vid = event:attr("vehicle_id") || vehicle_id();
      subscriptions = getSubscription(vid, event:attr("subscription_type"));
      subs = event:attr("filter") => subscriptions.filter(function(s){ s{"deletionTimestamp"}.isnull() })
                                   | subscriptions;
    }
    send_directive("Subscriptions for #{vid} (404 means no subscriptions)") with subscriptions = subs;
  }

  rule remove_all_subscriptions {
    select when carvoyant no_subscriptions_needed
    foreach getSubscription(vehicle_id()).filter(function(s){ s{"deletionTimestamp"}.isnull() }) setting(sub)
    pre {
      vid = vehicle_id();
      my_current_eci = get_eci_for_carvoyant();
      id = sub{"id"};	
      sub_type = sub{"_type"};
      postUrl = sub{"postUrl"};
    }
    if(postUrl.match("re#/#{my_current_eci}/#".as("regexp"))) then
    {
      send_directive("Will delete subscription #{id} with type #{sub_type}") with
        sub_value = sub;
      del_subscription(sub_type, id, vid)
        with ar_label = "subscription_deleted";
    }
  }

  rule clean_up_subscriptions {
    select when carvoyant dirty_subscriptions
    pre {
      my_subs =  getSubscription(vehicle_id()).filter(function(s){ s{"deletionTimestamp"}.isnull() });
    }
    if ( my_subs.length() > 0 ) then
      send_directive("checking subscriptions")
    fired {
      raise explicit event have_subscriptions_to_check
       with subscriptions = my_subs
    } else {
      raise fuse event need_initial_subscriptions
    }
  }

  rule clean_up_subscriptions_aux {
    select when explicit have_subscriptions_to_check
    foreach event:attr("subscriptions") setting(sub)
    pre {
      my_current_eci = get_eci_for_carvoyant();


      foo = sub.klog(">> the subscription >>");
      id = sub{"id"};	
      sub_type = sub{"_type"};
      postUrl = sub{"postUrl"};
      bad_subscription = (sub{"_type"}.klog(">> type >> ") eq "LOWBATTERY" &&
      		          sub{"notificationPeriod"}.klog(">> period >> ") eq "STATECHANGE")
		       || 
                         (sub{"_type"} eq "NUMERICDATAKEY" &&
                          sub{"dataKey"} eq "GEN_FUELLEVEL" &&
  	  	          sub{"notificationPeriod"} eq "STATECHANGE")
    }
    if( not postUrl.match("re#/#{my_current_eci}/#".as("regexp"))
     || bad_subscription.klog(">>> found an old fuel or battery subscription >> ")
      ) then
    {
      send_directive("Will delete subscription #{id} with type #{sub_type}") with
        sub_value = sub;
      del_subscription(sub_type, id, vehicle_id())
        with ar_label = "subscription_deleted";
    }
    always {
      raise fuse event need_initial_subscriptions
         on final; 
    }
  }

  // warning: this currently deletes ALL subscriptions and only puts back standard ones
  rule switch_subscription_host {
    select when carvoyant new_subscription_host
    foreach getSubscription(vehicle_id()).filter(function(s){ s{"deletionTimestamp"}.isnull() }) setting(sub)
    pre {
      id = sub{"id"};	
      sub_type = sub{"_type"};
      postUrl = sub{"postUrl"};
      my_current_eci = get_eci_for_carvoyant();
      // get rid of everything but the event stuff so we duplicate it, but with a new event host
      subscription = sub
                      .delete(["_timestamp"])
                      .delete(["postUrl"])
                      .delete(["id"])
                      .delete(["_type"])
		      .put(["event_host"], event:attr("event_host"))
		      .put(["subscription_type"], sub_type)
                      ;
      vid = vehicle_id();
      sub_target = event:attr("event_host");
       // params = {"id": id};
    }
    // only update Fuse subscriptions
    if(postUrl.match("re#/#{my_current_eci}/#".as("regexp"))) then
    {
       send_directive("Will delete subscription #{id} with type #{sub_type}") with
         sub_value = sub;
       del_subscription(sub_type, id, vid)
         with ar_label = "subscription_deleted";
         // send_directive("Updating subscription") with
	 //   attributes = event:attrs();
         // add_subscription(vid, sub_type, params, sub_target) with
    	 //   ar_label = "update_subscription";
    }
    fired {
       raise fuse event need_initial_subscriptions with
         event_host = sub_target 
         on final; 
        // raise carvoyantfuse event "new_subscription_needed" 
        //   attributes subscription
    }
  }


  // ---------- rules for handling notifications ----------

  rule process_ignition_on  {  
    select when carvoyant ignitionStatus where status eq "ON"
    pre {
      ignition_data = normalize_carvoyant_attributes(event:attrs());
    }
    noop();
    always {
      raise fuse event "trip_check" with duration = 2; // recover lost trips
      raise fuse event ignition_processed attributes ignition_data;
    }
  }

  rule process_ignition_off {  
    select when carvoyant ignitionStatus where status eq "OFF"
    pre {
      tid = event:attr("tripId");
      ignition_data = normalize_carvoyant_attributes(event:attrs());
    }
    if not tid.isnull() then noop();
    fired {
      raise fuse event "new_trip" with tripId = tid;
      raise fuse event ignition_processed attributes ignition_data;
    } else {
      error warn "No trip ID " + ignition_data.encode();
    }
  }

  rule post_process_ignition {
    select when fuse ignition_processed
    pre {
      ignition_data = event:attrs();
    }
    noop();
    always {
      raise fuse event "need_vehicle_status";
      raise pds event "new_data_available"
	  attributes {
	    "namespace": namespace(),
	    "keyvalue": "ignitionStatus_fired",
	    "value": ignition_data,
            "_api": "sky"
 		   
	  };
    }
  }

  rule lowBattery_status_changed  { 
    select when carvoyant lowBattery
    pre {
      threshold = event:attr("thresholdVoltage");
      recorded = event:attr("recordedVoltage");
      id = event:attr("id");
      about_me = pds:get_all_me();
      vehicle_name = about_me{"myProfileName"};
      device_id = about_me{"deviceId"};
      status = event:attrs()
                    .defaultsTo({})	
                    .put(["timestamp"], common:convertToUTC(time:now()))
		    .delete(["_generatedby"]);
   }
    noop();
    always {
      log "Recorded battery level: " + recorded;
      raise pds event "new_data_available"
	  attributes {
	    "namespace": namespace(),
	    "keyvalue": "lowBattery_fired for #{}",
	    "value": status,
            "_api": "sky"
 		   
	  };
      raise fuse event "updated_battery"
	  with threshold = threshold
	   and recorded = recorded
	   and activity = "Battery dropped below #{threshold}V to #{recorded}V for #{vehicle_name} (#{device_id})"
	   and reason = "Low battery report from #{vehicle_name}"
	   and id = id
          ;

    }
  }

  rule dtc_status_changed  { 
    select when carvoyant troubleCode
    pre {
      codes = event:attr("troubleCodes");
      id = event:attr("id");

      status = event:attrs()
                      .defaultsTo({})	
                      .put(["timestamp"], common:convertToUTC(time:now()))
                      .put(["translatedValues"], reason_string)
	              .delete(["_generatedby"]);


      about_me = pds:get_all_me();
      vehicle_name = about_me{"myProfileName"};
      device_id = about_me{"deviceId"};

      details = dataSet(event:attr("vehicleId"),event:attr("dataSetId")).defaultsTo([]);
      
      detail = details
                  .filter(function(rec) {rec{["datum","key"]} eq "GEN_DTC"} )
		  ; 

      reason_string = detail
                         .map( function(rec) { rec{["datum","translatedValue"]} } )
			 .join("; ")
			 ;


    }
    noop();
    always {
      log "Recorded trouble codes: " + codes.encode();
      raise pds event "new_data_available"
	  attributes {
	    "namespace": namespace(),
	    "keyvalue": "troubleCode_fired",
	    "value": status.put(["detauls"], detail.encode()),
            "_api": "sky"
          };
     raise fuse event "updated_dtc"
	  with dtc = codes
	   and timestamp = status{"timestamp"} 
	   and activity = "#{vehicle_name} (#{device_id}) reported the following diagnostic codes: " + codes.encode()
	   and reason = "Diagnostic code report from #{vehicle_name}: " + reason_string
	   and id = id
          ;

    }
  }

  rule catch_fuel_level { 
    select when carvoyant numericDataKey dataKey "GEN_FUELLEVEL"
    pre {
      foo = event:attrs().klog(">> seeing these attributes >>"); 
      about_me = pds:get_all_me();
      vehicle_name = about_me{"myProfileName"};
      device_id = about_me{"deviceId"};
 
      threshold = event:attr("thresholdValue");
      recorded = event:attr("recordedValue");
      relationship = event:attr("relationship").defaultsTo("ABOVE");

      status = {"timestamp": common:convertToUTC(time:now()),
                "threshold": threshold,
      		"recorded": recorded,
      		"relationship": relationship,
		"id": event:attr("id"),
		"activity": "Fuel level for #{vehicle_name} (#{device_id}) of #{recorded}% is #{relationship.lc()} threshold value of #{threshold}%",
		"reason": "Fuel report from #{vehicle_name}"
               };
	
    }
    noop();
    always {
      raise pds event "new_data_available"
	  attributes {
	    "namespace": namespace(),
	    "keyvalue": "fuelLevel_fired",
	    "value": status,
            "_api": "sky"
 		   
     };
     raise fuse event "updated_fuel_level" attributes status ;
    }
  }

  rule catch_device_status_changed { 
    select when carvoyant vehicleConnected
             or carvoyant vehicleDisconnected
    pre {

      about_me = pds:get_all_me();
      vehicle_name = about_me{"myProfileName"};
      device_id = about_me{"deviceId"};

      device_status = event:type() eq vehicleConnected => "connected"  | "disconnected";
      status = event:attrs()
                    .defaultsTo({})	
                    .put(["timestamp"], common:convertToUTC(time:now()))
		    .put(["activity"], "Fuse device #{device_id} in #{vehicle_name} is #{device_status}")
		    .put(["reason"], "Device report from #{vehicle_name}")
		    .delete(["_generatedby"])
		    .klog(">> device status >>")
		    ;
    }
    noop();
    always {
     raise fuse event "updated_device_status" attributes status ;
    }
  }

  rule catch_vehicle_moving { 
    select when carvoyant numericDataKey dataKey "GEN_SPEED"
    pre {
      threshold = event:attr("thresholdValue");
      recorded = event:attr("recordedValue");
      relationship = event:attr("relationship");
      status = event:attrs()
                 .put(["timestamp"], common:convertToUTC(time:now()))
                 .delete(["_generatedby"]);
      id = event:attr("id");
    }
    noop();
    always {
      log "Vehicle speed of #{recorded}% is #{relationship.lc()} threshold value of #{threshold}";
      raise fuse event "need_vehicle_status";
      raise pds event "new_data_available"
        attributes {
	    "namespace": namespace(),
	    "keyvalue": "vehicle_moving_fired",
	    "value": status,
            "_api": "sky"
	  } if false; // don't put in PDS now
    }
  }


  // ---------- error handling ----------
  rule carvoyant_http_fail {
    select when http post status_code re#([45]\d\d)# setting (status)
             or http put status_code re#([45]\d\d)# setting (status)
             or http delete status_code re#([45]\d\d)# setting (status) 
   pre {
      returned = event:attrs();
      tokens = getTokens().encode({"pretty": true, "canonical": true});
      vehicle_info = pds:get_item(namespace(), "vehicle_info")
                      .delete(["myProfilePhoto"])
                      .delete(["profilePhoto"])
		      .encode({"pretty": true, "canonical": true});
      url =  ent:last_carvoyant_url;
      params = ent:last_carvoyant_params;
      type = event:type();

      error_msg = returned{"content"}.decode() || {};

      errorCode = error_msg{["error","errorCode"]} || "";
      detail = error_msg{["error","detail"]} || "";
      field_errors  = error_msg{["error","fieldErrors"]}.encode({"pretty": true, "canonical": true}) || [];
      reason =  error_msg{["error","errorDisplay"]} || "";

      attrs = event:attrs().encode({"pretty": true, "canonical": true});

      owner = common:fleetChannel();
      

      msg = <<
Carvoyant HTTP Error (#{status}): #{event:attr('status_line')}

Autoraise label: #{event:attr('label')}

Attributes #{attrs} 

Error Code: #{errorCode}

Detail: #{detail}

Reason: #{reason}

Field Errors: #{field_errors}

Tokens #{tokens}

Vehicle info: #{vehicle_info}

Carvoyant URL: #{url}

Carvoyant Params: #{params}

HTTP Method: #{type}
>>;

    }
    {
      send_directive("carvoyant_fail") with
        sub_status = returned and
        error_code = errorCode and
        detail = detail and
	reason = reason and
        field_errors = field_errors
	;
       event:send({"eci": owner}, "fuse", "vehicle_error") with
         attrs = {
          "error_type": returned{"label"},
          "reason": reason,
          "error_code": errorCode,
          "detail": detail,
          "field_errors": error_msg{["error","fieldErrors"]},
	  "set_error": true
	 }
         ;
    }	
    fired {
      error warn msg
    }
  }


// fuse_carvoyant.krl
}
