var browserIE = false;
var otgjsButtons = [];
var otgjsMessage;
var otgjsConfig;
var otgjsMonitorBars;

var OTG_GATEWAY_SID = "urn:otgw-tclcode-com:serviceId:OpenThermGateway1";

// UI5 (0) vs UI7 (1)
var otgjsUiVersion = 0;

// Flag ID, y, x1, x2
var otgjsInfoFlagLayout = [
   [0x0100,  15,  30, 190], // Central Heating enable
   [0x0200,  30,  30, 190], // Domestic Hot Water enable
   [0x0400,  45,  30, 190], // Cooling enable
   [0x0800,  60,  30, 190], // OTC active
   [0x1000,  75,  30, 190], // Central Heating 2 enable
   [0x0001,  90,  30, 190], // Fault indication
   [0x0002,  15, 235, 390], // Central Heating mode
   [0x0004,  30, 235, 390], // Domestic Hot Water mode
   [0x0008,  60, 235, 390], // Flame status
   [0x0010,  45, 235, 390], // Cooling status
   [0x0020,  75, 235, 390], // Central Heating 2 mode
   [0x0040,  90, 235, 390]  // Diagnostic indication
];

// Fault ID, y, x1, x2
var otgjsInfoFaultLayout = [
   [0x0100,  15, 435, 580],
   [0x0200,  30, 435, 580],
   [0x0400,  45, 435, 580],
   [0x0800,  60, 435, 580],
   [0x1000,  75, 435, 580],
   [0x2000,  90, 435, 580]
];

// Message ID, y, x1, x2, optional: index hb/lb, optional: max (for bar)
// Note: min & max are not OpenTherm specified, but display specific (i.e. not theoretic, but values that make sense)
var otgjsInfoMsgLayout = [
   [ 1, 210,  30, 210, '',  0, 100], // Control setpoint
   [ 5, 270,  30, 210, 'lb'],        // OEM fault code
   [ 8, 270, 335, 525, '',  0, 100], // Control setpoint central heating 2
   [ 9, 170,  30, 210, '', 10,  30], // Remote override room setpoint
   [14, 250,  30, 210, '',  0, 100], // Maximum relative modulation level
   [16, 150,  30, 210, '', 10,  30], // Room setpoint
   [17, 230,  30, 210, '',  0,'14'], // Relative modulation level; max = value of msg 14
   [18, 230, 335, 525, '',  0,   5], // Central heating water pressure
   [23, 250, 335, 525, '',  0, 100], // Room setpoint central heating 2
   [24, 130,  30, 210, '', 10,  30], // Room temperature
   [25, 170, 335, 525, '', 30, 100], // Boiler water temperature
   [26, 130, 335, 525, '', 30, 100], // DHW temperature
   [27, 190,  30, 210],           // Outside temperature
   [28, 190, 335, 525, '', 30, 100], // Return water temperature
   [56, 150, 335, 525, '',  0, 100], // DHW setpoint
   [57, 210, 335, 525, '',  0, 100]  // Max CH water setpoint
];

//------------
// Monitor tab

function otgjsMonitorTab(deviceID) {
   // Determine if monitor bars will be used
   otgjsMonitorBars = get_device_state(deviceID, OTG_GATEWAY_SID, "PluginMonitorBars", 0);
   var html = '<style type="text/css">input {margin:0px;} .skinned-form-controls input[type="checkbox"]:disabled + span, .skinned-form-controls input[type="checkbox"]:disabled + span:before {opacity: 1.0;} ';
   html += 'div.hr {height: 1px; background-image: -webkit-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0)); '; 
   html += 'background-image:    -moz-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.75), rgba(0,0,0,0)); '; 
   html += 'background-image:     -ms-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0)); '; 
   html += 'background-image:      -o-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0));} ';
   html += '.otgprogress {width: 70px; border: 0px;} ';
   html += '.otgprogress-bar {background-color: #AAAAAA; box-shadow: 1px 1px 1px #444444; width: 0%; height: 15px; opacity: 0.3; border-radius: 4px;} ';
   html += 'div.err {color: #ABABAB}</style>';
   for (var i=0; i<otgjsInfoFlagLayout.length; i++) {
      html += '<div class="label" id="flag'+otgjsInfoFlagLayout[i][0]+'" style="position: absolute; top: '+otgjsInfoFlagLayout[i][1]+'px; left: '+otgjsInfoFlagLayout[i][2]+'px;"></div>';
      html += '<div class="skinned-form-controls skinned-form-controls-mac" id="flagval'+otgjsInfoFlagLayout[i][0]+'" style="position: absolute; top: '+otgjsInfoFlagLayout[i][1]+'px; left: '+otgjsInfoFlagLayout[i][3]+'px;">';
      html += '<input type="checkbox" id="flagcheck'+otgjsInfoFlagLayout[i][0]+'" disabled><span></span></div>';
   }
   for (var i=0; i<otgjsInfoFaultLayout.length; i++) {
      html += '<div class="label" id="fault'+otgjsInfoFaultLayout[i][0]+'" style="position: absolute; top: '+otgjsInfoFaultLayout[i][1]+'px; left: '+otgjsInfoFaultLayout[i][2]+'px;"></div>';
      html += '<div class="skinned-form-controls skinned-form-controls-mac" id="faultval'+otgjsInfoFaultLayout[i][0]+'" style="position: absolute; top: '+otgjsInfoFaultLayout[i][1]+'px; left: '+otgjsInfoFaultLayout[i][3]+'px;">';
      html += '<input type="checkbox" id="faultcheck'+otgjsInfoFaultLayout[i][0]+'" disabled><span></span></div>';
   }
   html += '<div class="hr" style="position: absolute; top: 120px; left: 28px; width: 570px;"></div>';
   for (var i=0; i<otgjsInfoMsgLayout.length; i++) {
      var msgNr = otgjsInfoMsgLayout[i][0];
      var y = otgjsInfoMsgLayout[i][1];
      var x2 = otgjsInfoMsgLayout[i][3];
      html += '<div class="label" id="msg'+msgNr+'" style="position: absolute; top: '+y+'px; left: '+otgjsInfoMsgLayout[i][2]+'px;"></div>';
      html += '<div class="variable" id="msgval'+msgNr+'" style="position: absolute; top: '+y+'px; left: '+x2+'px; width: 50px; text-align: right"></div>';
      html += '<div class="variable" id="msgunit'+msgNr+'" style="position: absolute; top: '+y+'px; left: '+(x2+55)+'px;"></div>';
      if (otgjsMonitorBars > 0 && otgjsInfoMsgLayout[i][5] !== null) {
         html += '<div class="otgprogress" style="position: absolute; top: '+(y-1)+'px; left: '+(x2+3)+'px;"><div class="otgprogress-bar" id="msgbar'+msgNr+'"></div></div>';
      }
   }
   html += '<div class="hr" style="position: absolute; top: 300px; left: 28px; width: 570px;"></div>';
   for (var i=0; i<4; i++) {
      html += '<div class="err" id="err'+i+'" style="position: absolute; top: 310px; left: '+(50+145*i)+'px;" onClick="otgjsResetError('+deviceID+','+i+')" title="Click to reset Error 0'+(i+1)+'">';
      html += '</div><div class="err" id="errval'+i+'" style="position: absolute; top: 310px; left: '+(100+145*i)+'px; width: 30px; text-align: right"></div>';
   }
   otgjsDetectBrowser();
   otgjsSetHTML(html);
   if (otgjsMessage === undefined) {
      otgjsGetInfo(deviceID, OTG_GATEWAY_SID, 'GetMessages', otgjsMonitorConfig);
   } else {
      otgjsMonitorConfig(deviceID, otgjsMessage);
   }
}

// On click of error text reset the count to zero
function otgjsResetError(deviceID, n) {
   otgjsCallAction(deviceID, OTG_GATEWAY_SID, "ResetErrorCount", {'Index': n+1});
}

// taken from UI5 for UI7 compatibility
function get_lu_status_device_obj(deviceID){

    var devicesCount=jsonp.ud.devices.length;
    for(var i=0;i<devicesCount;i++){
        if(jsonp.lu.devices[i] && jsonp.lu.devices[i].id==deviceID){
            return jsonp.lu.devices[i];
        }
    }
}

// Get the value of a variable out of the device state
function otgjsGetVariableState(deviceObj, variable) {
   if (deviceObj && deviceObj.states) {
      var statesNo = deviceObj.states.length;
      for (var i=0; i<statesNo; i++) {
         var stateObj = deviceObj.states[i];
         if(stateObj && stateObj.service == OTG_GATEWAY_SID && stateObj.variable == variable) {
            return stateObj.value;
         }
      }
   }
   return undefined
}

function otgjsDisplayMonitor(deviceID) {
   // Keep updating while we are on this tab
   if (document.getElementById('msg'+otgjsInfoMsgLayout[0][0]) !== null) {
      // Get the state of the device
      var deviceObj = get_lu_status_device_obj(deviceID);
      // Update flag values
      for (var i=0; i<otgjsInfoFlagLayout.length; i++) {
         var elem = document.getElementById('flagcheck'+otgjsInfoFlagLayout[i][0]);
         var msg = otgjsMessage[0].flags[otgjsInfoFlagLayout[i][0]];
         var val = otgjsGetVariableState(deviceObj, msg['var']);
         elem.checked = (val == "1");
      }
      // Update fault values
      for (var i=0; i<otgjsInfoFaultLayout.length; i++) {
         var elem = document.getElementById('faultcheck'+otgjsInfoFaultLayout[i][0]);
         var msg = otgjsMessage[5].flags[otgjsInfoFaultLayout[i][0]];
         var val = otgjsGetVariableState(deviceObj, msg['var']);
         elem.checked = (val == "1");
      }
      // Update message values
      for (var i=0; i<otgjsInfoMsgLayout.length; i++) {
         var msgNr = otgjsInfoMsgLayout[i][0];
         var txt = document.getElementById('msg'+msgNr);
         var elem = document.getElementById('msgval'+msgNr);
         var unit = document.getElementById('msgunit'+msgNr);
         var bar = document.getElementById('msgbar'+msgNr);
         var msg = otgjsMessage[msgNr];
         var msgVar = msg['var'];
         if (typeof(msgVar) == 'object') {
            msgVar = msgVar[otgjsInfoMsgLayout[i][4]]
         }
         var val = otgjsGetVariableState(deviceObj, msgVar);
         if ((val == null || val == "") && elem.style.color == "") {
            txt.style.color = elem.style.color = unit.style.color = '#DDDDDD';
            elem.innerHTML = '???';
            if (bar != null) { bar.style.width = '0%'; }
         } else if (val != null && val != "") {
            if (elem.style.color != "") {
               txt.style.color = elem.style.color = unit.style.color = '';
            }
            if (val == elem.innerHTML) {
               elem.style.fontWeight = '';
            } else {
               elem.style.fontWeight = 'bold';
               elem.innerHTML = val;
               if (bar != null) {
                  var min = otgjsInfoMsgLayout[i][5];
                  var max = otgjsInfoMsgLayout[i][6];
                  if (typeof(max) == 'string') {
                     max = parseFloat(otgjsGetVariableState(deviceObj, otgjsMessage[max]['var']));
                  }
                  val = parseFloat(val);
                  if (val < min) { val = 0; } else
                  if (val > max) { val = 100; } else {
                     val = Math.round((val - min) / (max - min) * 100);
                  }
                  bar.style.width = val+'%';
                  if (otgjsMonitorBars > 1 && unit.innerHTML.search(/.C/) == 0) {
                     /* start color = #00CCEE */
                     var r = Math.round(0xFF*val/100);
                     var g = Math.round(0x44 + 0x88*(100-val)/100);
                     var b = Math.round(0xFF*(100-val)/100);
                     var color = 'rgb('+r+','+g+','+b+')';
                     bar.style.backgroundColor = color;
                  }
               }
            }
         }
      }
      // Update error count
      var val = otgjsGetVariableState(deviceObj, "Errors");
      var val_a = val.split(',');
      for (var i=0; i<val_a.length; i++) {
         var elem = document.getElementById('errval'+i);
         elem.innerHTML = val_a[i];
      }
      setTimeout("otgjsDisplayMonitor("+deviceID+")", 1000);
   }
};

function otgjsMonitorConfig(deviceID, result) {
   otgjsMessage = result;
   /*
   // Add child device IDs to messages
   for (var i=0; i<jsonp.ud.devices.length; i++) {
      if (jsonp.ud.devices[i].id_parent == deviceID) {
         var msgNr = jsonp.ud.devices[i].altid.replace('msg', '');
         otgjsMessage[msgNr].childDevice = jsonp.ud.devices[i].id;
      }
   }
   */
   // Add flag labels
   for (var i=0; i<otgjsInfoFlagLayout.length; i++) {
      var elem = document.getElementById('flag'+otgjsInfoFlagLayout[i][0]);
      var msg = otgjsMessage[0].flags[otgjsInfoFlagLayout[i][0]];
      elem.innerHTML = msg.txt;
   }
   // Add fault labels
   for (var i=0; i<otgjsInfoFaultLayout.length; i++) {
      var elem = document.getElementById('fault'+otgjsInfoFaultLayout[i][0]);
      var msg = otgjsMessage[5].flags[otgjsInfoFaultLayout[i][0]];
      elem.innerHTML = msg.txt;
   }
   // Add message labels
   for (var i=0; i<otgjsInfoMsgLayout.length; i++) {
      var msgNr = otgjsInfoMsgLayout[i][0];
      var elem = document.getElementById('msg'+msgNr);
      var msg = otgjsMessage[msgNr];
      var txt = msg.txt;
      var n = txt.search(/\([^\)]+\)/);
      var unit = "";
      if (n > 0) {
         unit = txt.substring(n+1, txt.length-1).replace('°', '&deg;');
         txt = txt.substr(0, n-1);
      }
      var sub = otgjsInfoMsgLayout[i][4];
      if (sub != null && sub != '') {
         var n = txt.search("&");
         if (sub == 'lb') { txt = txt.substr(n+1); } else { txt = txt.substr(0, n-1); }
      }
      elem.innerHTML = txt;
      document.getElementById('msgunit'+msgNr).innerHTML = unit;
   }
   // Add error labels
   for (var i=0; i<4; i++) {
      var elem = document.getElementById('err'+i);
      elem.innerHTML = "Error 0"+(i+1)+":";
   }
   otgjsDisplayMonitor(deviceID);
};

//--------
// Eco tab

function otgjsEcoTab(deviceID) {
   var html = '<table width="80%" border="0" cellspacing="2" cellpadding="0">';
   
   var partitions = [{value:'',label:'None'}];
   var yesNo = [{value:'',label:'N/A'},{value:'1',label:'Yes'}];
   var doors = [];
   // Find alarm panel partitions
   for (var i=0; i<jsonp.ud.devices.length; i++){
      if (jsonp.ud.devices[i].category_num == 23) {
         partitions.push({'value':jsonp.ud.devices[i].id,'label':jsonp.ud.devices[i].name});
      } else if (jsonp.ud.devices[i].category_num == 4 && jsonp.ud.devices[i].subcategory_num == 1) {
         doors.push({'value':jsonp.ud.devices[i].id,'label':jsonp.ud.devices[i].name});
      }
   }
   var tempOptions = [{'value':'0','label':'No'}];
   for (var i=1; i<=5; i++) {
      tempOptions.push({'value':'-'+i,'label':i+' &deg;C lower'});
   }
   for (var i=15; i<=22; i++) {
      tempOptions.push({'value':i,'label':'Set to '+i+'&deg;C'});
   }
   var minutes = [{value:'',label:'N/A'},{value:'1',label:'1 minute'}];
   for (var i=2; i<=10; i++) {
      minutes.push({'value':i,'label':i+' minutes'});
   }
   var dhwOptions = [{'value':'0','label':'No'},{'value':'1','label':'Disable'},{'value':'2','label':'Set to Automatic'}];
   // Default Eco
   html += '<tr><td colspan="3"><div class="label"><b>Default Eco mode options</b></div></td></tr>';
   html += otgjsAddPulldown(deviceID, 'Change domestic hot water', 'PluginEcoDHW', dhwOptions);
   html += otgjsAddPulldown(deviceID, 'Change room setpoint', 'PluginEcoTemp', tempOptions);
   // Away Eco
   html += '<tr><td colspan="3"><div class="label"><b>Eco options when Armed Away</b></div></td></tr>';
   if (partitions.length != 1) {
      html += otgjsAddPulldown(deviceID, 'Select alarm panel partition device', 'PluginPartitionDevice', partitions);
      html += otgjsAddPulldown(deviceID, 'Change domestic hot water', 'PluginArmedAwayDHW', dhwOptions);
      html += otgjsAddPulldown(deviceID, 'Change room setpoint', 'PluginArmedAwayTemp', tempOptions);
   } else {
      html += '<tr><td colspan="3"><i>No alarm partition found.</i></td></tr>';
   }
   // Open Eco
   html += '<tr><td colspan="3"><div class="label"><b>Eco options when a door/window is open</b></div></td></tr>';
   if (doors.length != 0) {
      html += otgjsAddPulldown(deviceID, 'Select door/window devices', 'PluginDoorWindowDevices', doors, true);
      html += otgjsAddPulldown(deviceID, 'Change room setpoint', 'PluginDoorWindowTemp', tempOptions);
      html += otgjsAddPulldown(deviceID, 'Option: only when it is open for more than', 'PluginDoorWindowMinutes', minutes);
      var outsideTemp = get_device_state(deviceID, OTG_GATEWAY_SID, "OutsideTemperature", 0);
      if (outsideTemp !== undefined) {
         html += otgjsAddPulldown(deviceID, 'Option: only when it is colder outside than inside', 'PluginDoorWindowOutside', yesNo);
      }
   } else {
      html += '<tr><td colspan="3"><i>No door sensor found.</i></td></tr>';
   }

   html += '</table>';
   otgjsSetHTML(html);
}

//------------------
// Hardware tab: OTG hardware configuration

function otgjsHardwareTab(deviceID) {
   if (otgjsConfig === undefined) {
      otgjsGetInfo(deviceID, OTG_GATEWAY_SID, 'GetConfiguration', otgjsHardwareConfig);
   } else {
      otgjsHardwareConfig(deviceID, otgjsConfig);
   }
}

function otgjsHardwareConfig(deviceID, result) {
   otgjsConfig = result;

   var showConfig = ['GW', 'REF', 'ITR', 'ROF', 'GPIO', 'LED'];
   var html = '<style>span.customStyleSelectBox {border:0}</style>';
   html += '<table width="100%" border="0" cellspacing="3" cellpadding="0">';
   html += '<tr><td colspan="3"><div class="label"><b>Gateway configuration</b></div></td></tr>';
   for (var i=0; i<showConfig.length; i++) {
      var elem = showConfig[i];
      if (otgjsConfig[elem] !== undefined) {
         var list = [];
         for (var prop in otgjsConfig[elem].tab) {
            list.push({ 'value':prop,'label':otgjsConfig[elem].tab[prop].txt });
         }
         if (otgjsConfig[elem].cnt === undefined) {
            html += otgjsAddPulldown(deviceID, otgjsConfig[elem].txt, otgjsConfig[elem].var, list);
         } else {
            for (var j=0; j<otgjsConfig[elem].cnt; j++){
               html += otgjsAddPulldown(deviceID, elem+' '+String.fromCharCode(65+j)+' function', otgjsConfig[elem].var+j, list);
            }
         }
      }
   }
   html += '</table>';
   otgjsSetHTML(html);
}

//-------------
// Settings tab: plugin configuration

function otgjsSettingsTab(deviceID) {
   if (otgjsMessage === undefined) {
      otgjsGetInfo(deviceID, OTG_GATEWAY_SID, 'GetMessages', otgjsSettingsConfig);
   } else {
      otgjsSettingsConfig(deviceID, otgjsMessage);
   }
}

function otgjsSettingsConfig(deviceID, result) {
   otgjsMessage = result;
 
   var deviceObj = get_device_obj(deviceID);
   var devicePos = get_device_index(deviceID);
   var html = '<style>span.customStyleSelectBox {border:0}</style>';
   html += '<table width="100%" border="0" cellspacing="3" cellpadding="0">';
   html += '<tr><td colspan="3"><div class="label"><b>Plugin options</b></div></td></tr>';
   
   if (deviceObj.commUse) {
      html += '<tr>';
      html += ' <td width="230">Communicate using UART</td>';
      html += ' <td width="100" colspan="2">' + CommProv_pulldown(deviceID) + '</td>';
      html += '</tr>';
   } else if (deviceObj.ip) {
      html += '<tr>';
      html += ' <td width="230">Communicate using IP</td>';
      html += ' <td colspan="2"><input type="text" id="device_'+deviceID+'_IP" value="'+((deviceObj.ip)?deviceObj.ip:'')+'" onChange="update_device('+deviceID+',this.value,\'jsonp.ud.devices['+devicePos+'].ip\');" class="inputbox"></td>';
      html += '</tr>';
   }
   // Make list of temerature sensors; exclude our own
   var tempSensors = [{'value':'','label':'None'}];
   var childMsg = [];
   var i;
   for (i=0; i<jsonp.ud.devices.length; i++) {
      if (jsonp.ud.devices[i].category_num == 17 && jsonp.ud.devices[i].id_parent != deviceID) {
         tempSensors.push({ 'value':jsonp.ud.devices[i].id,'label':jsonp.ud.devices[i].name });
      }
   }
   var humiditySensors = [{'value':'','label':'None'}];
   for (i=0; i<jsonp.ud.devices.length; i++) {
      if (jsonp.ud.devices[i].category_num == 16) {
         humiditySensors.push({ 'value':jsonp.ud.devices[i].id,'label':jsonp.ud.devices[i].name });
      }
   }
   for (i=0; i<=128; i++) {
      if (otgjsMessage[i] != null && otgjsMessage[i].child != null) {
         var name = otgjsMessage[i].txt.replace(/\s\(.+/g, "");
         childMsg.push({ 'value':i,'label':name });
      }
   }
   var bars =  [{'value':'0','label':'Off'},{'value':'1','label':'Single color'},{'value':'2','label':'Temperature relative'}];
   var onOff = [{'value':'0','label':'Off'},{'value':'1','label':'Message file'},{'value':'3','label':'File & debug statements'},{'value':'7','label':'File & debug & messages'},{'value':'15','label':'File & debug & messages & flags'}];
   var yesNo = [{'value':'0','label':'No'},{'value':'1','label':'Yes'}];
   var clock = [{'value':'0','label':'No'},{'value':'1','label':'Only time'},{'value':'2','label':'Date and time'},{'value':'3','label':'Date, time and year'}];
   html += otgjsAddPulldown(deviceID, 'Generate debug logging & files', 'PluginDebug', onOff);
   if (tempSensors.length > 0) {
      html += otgjsAddPulldown(deviceID, 'Outside temperature sensor', 'PluginOutsideSensor', tempSensors);
   }
   if (humiditySensors.length > 0) {
      html += otgjsAddPulldown(deviceID, 'Room humidity sensor', 'PluginHumiditySensor', humiditySensors);
   }
   html += otgjsAddPulldown(deviceID, 'Use child device for temperature', 'PluginHaveChildren', childMsg, true);
   html += otgjsAddPulldown(deviceID, 'Create child devices embedded', 'PluginEmbedChildren', yesNo);
   html += otgjsAddPulldown(deviceID, 'Show monitor bar indicator', 'PluginMonitorBars', bars);
   html += otgjsAddPulldown(deviceID, 'Automatically update the gateway clock', 'PluginUpdateClock', clock);
   html += '</table>';
   otgjsSetHTML(html);
}

function otgjsUpdate(deviceID, variable, value) {
   var idx = variable.match(/\d+/g);
   if (idx != null) {
      var name = variable.substring(0, variable.length-1)
      var state = get_device_state(deviceID, OTG_GATEWAY_SID, name, 0);
      value = state.substr(0, idx) + value + state.substr(idx+1);
      set_device_state(deviceID, OTG_GATEWAY_SID, name, value, 0);
   } else {
      var value = [];
      var s = document.getElementById(variable+"Select");
      for (var i = 0; i < s.options.length; i++) {
         if (s.options[i].selected == true) {
            value.push(s.options[i].value);
         }
      }
      set_device_state(deviceID, OTG_GATEWAY_SID, variable, value.join(), 0);
   }
}

function otgjsAddPulldown(deviceID, label, variable, values, multiple, extra) {
   multiple = (multiple == null) ? false : multiple;
   extra = (extra == null) ? '' : extra;
   var selected;
   var idx = variable.match(/\d+/g);
   if (idx != null) {
      var name = variable.substring(0, variable.length-1)
      var state = get_device_state(deviceID, OTG_GATEWAY_SID, name, 0);
      if (state == null || selected == "") {
         state = get_device_state(deviceID, OTG_GATEWAY_SID, name, 1); // reading latest state
      }
      selected = (state == null ? '' : state.substr(Number(idx), 1));
   } else {
      selected = get_device_state(deviceID, OTG_GATEWAY_SID, variable, 0);
      if (selected == null || selected == "") {
         selected = get_device_state(deviceID, OTG_GATEWAY_SID, variable, 1); // reading latest state
      }
   }
   var pulldown = pulldown_from_array(values, variable + 'Select', selected, 'onChange="otgjsUpdate('+deviceID+', \''+variable+'\', this.value)"');
   var html = '<tr><td><div class="label" id="'+variable+'">'+label+'</div></td><td colspan="2">'+pulldown+'</td><td>'+extra+'</td></tr>';

   // multi-select not handled properly by MCV
   if (multiple == true) {
      html = html.replace('class="styled"', 'multiple style="font-size:11px"');
      if (selected != null && selected != "") {
         selected = selected.split(",")
         for (var i = 0; i < selected.length; i++) {
            html = html.replace('"'+selected[i]+'"', '"'+selected[i]+'" selected');
         }
      }
   }

   return html;
}

//------------------
// Generic functions

function otgjsSetHTML(html) {
   if (typeof MMS !== 'undefined') {
      otgjsUiVersion = 1; // UI7
      html = '<div id="cpanel_control_tab_content" class="cpanel_control_tab_content">' + html + '</div>';
      html = html.replace(/class="button/g, 'class="cpanel_device_control_button');
      html = html.replace(/class="label/g, 'class="cpanel_device_control_label');
      html = html.replace(/class="variable/g, 'class="cpanel_device_control_variable');
   }
   set_panel_html(html);
}

function otgjsDetectBrowser() {
   var place = navigator.userAgent.toLowerCase().indexOf('msie');
   browserIE = (place != -1)
}

function otgjsCallAction(device, sid, actname, args) {
   var result;
   var q = {
      'id': 'lu_action',
      'output_format': 'xml',
      'DeviceNum': device,
      'serviceId': sid,
      'action': actname
   };
   var key;
   for (key in args) {
      q[key] = args[key];
   }
   if (browserIE) {
      q['timestamp'] = new Date().getTime(); //we need this to avoid IE caching of the AJAX get
   }
   new Ajax.Request (command_url+'/data_request', {
      method: 'get',
      parameters: q,
      onSuccess: function (response) {
         result = response.responseText;
      },
      onFailure: function (response) {
      }
   });
   return result;
}

function otgjsGetInfo(device, sid, what, func) {
   var result;
   new Ajax.Request(command_url+"/data_request", { 
     method: 'get', 
     parameters: { 
         id: 'lr_' + what + device,
         serviceId: sid,
         DeviceNum: device,
         output_format: 'json'
     },
     onSuccess: function (response) { 
         result = response.responseText.evalJSON();
         func(device, result);
     },
     onFailure: function (response) {
     }
   });
}
