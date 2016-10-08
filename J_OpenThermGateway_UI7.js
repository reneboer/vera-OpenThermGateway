//# sourceURL=J_OpenThermGateway_UI7.js
// OpenTherm Gateway UI for UI7
// Written by nlrb, modified for UI7 and ALTUI by Rene Boer. 
// V2.7 13 September 2016
var OpenThermGateway = (function (api) {
	var _DIV_PREFIX = "otgJS_";		// Used in HTML div IDs to make them unique for this module
	var _MOD_PREFIX = "OpenThermGateway";  // Must match module name above

	// Constants. Keep in sync with LUA code.
    var _uuid = '12021512-0000-a0a0-b0b0-c0c030303032';
	var otgjsButtons = [];
	var otgjsMessage;
	var otgjsConfig;
	var otgjsMonitorBars;

	var _SID = "urn:otgw-tclcode-com:serviceId:OpenThermGateway1";

	// Flag ID1, flag ID2, fault id
	var otgjsInfoLayout = [
		[0x0100,  0x0002, 0x0100], // Central Heating enable, 		Central Heating mode,		Service request
		[0x0200,  0x0004, 0x0200], // Domestic Hot Water enable, 	Domestic Hot Water mode		Lockout-reset
		[0x0400,  0x0010, 0x0400], // Cooling enable, 				Cooling status				Low water pressure
		[0x0800,  0x0008, 0x0800], // OTC active, 					Flame status				Gas/flame fault
		[0x1000,  0x0020, 0x1000], // Central Heating 2 enable,		Central Heating 2 mode		Air pressure fault
		[0x0001,  0x0040, 0x2000]  // Fault indication,				Diagnostic indication		Water over-temperature
	];

	// Message ID, optional: index hb/lb, optional: max (for bar)
	// Note: min & max are not OpenTherm specified, but display specific (i.e. not theoretic, but values that make sense)
	var otgjsInfoMsgLayout = [
		[24, '', 10,  30], // Room temperature
		[26, '', 30, 100], // DHW temperature
		[16, '', 10,  30], // Room setpoint
		[56, '',  0, 100], // DHW setpoint
		[ 9, '', 10,  30], // Remote override room setpoint
		[25, '', 30, 100], // Boiler water temperature
		[27],	           // Outside temperature
		[28, '', 30, 100], // Return water temperature
		[ 1, '',  0, 100], // Control setpoint
		[57, '',  0, 100],  // Max CH water setpoint
		[17, '',  0,'14'], // Relative modulation level; max = value of msg 14
		[18, '',  0,   5], // Central heating water pressure
		[14, '',  0, 100], // Maximum relative modulation level
		[23, '',  0, 100], // Room setpoint central heating 2
		[ 5, 'lb'],        // OEM fault code
		[ 8, '',  0, 100] // Control setpoint central heating 2
	];


	// Forward declaration.
    var myModule = {};

    function _onBeforeCpanelClose(args) {
		showBusy(false);
    }

    function _init() {
        // register to events...
        api.registerEventHandler('on_ui_cpanel_before_close', myModule, 'onBeforeCpanelClose');
    }

	//------------
	// Monitor tab

	function _Monitor() {
		var deviceID = api.getCpanelDeviceId();
		try {

			// Determine if monitor bars will be used
			otgjsMonitorBars = varGet(deviceID, "PluginMonitorBars");
			
			var html = '<style type="text/css">'+
					'div.hr {height: 1px; margin-bottom: 5px; background-image: -webkit-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0)); '+
					'background-image: -moz-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.75), rgba(0,0,0,0)); '+
					'background-image: -ms-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0)); '+
					'background-image: -o-linear-gradient(left, rgba(0,0,0,0), rgba(200,200,200,0.9), rgba(0,0,0,0));} '+
					'label.otg_progress {width: 70px; border: 0px;} '+
					'div.otg_progress-bar {background-color: #AAAAAA; box-shadow: 1px 1px 1px #444444; width: 0%; height: 20px; opacity: 0.3; border-radius: 4px;} '+
					'label.otg_var, input.otg_var {font-size: 15px; font-weight: normal;}'+
					'label.otg_err {font-size: 15px; font-weight: normal; color: #ABABAB}</style>';
			// Flag and fault messages in three columns
			html += '&nbsp;<div class="container-fluid">';
			$.each(otgjsInfoLayout, function (key,row){ 
				html += '<div class="row">';
				for (var j=0; j<3; j++) {
					var msgID = row[j];
					var msgTp = (j===2 ? 'fault' : 'flag');
					html += ' <div class="col-xs-12 col-sm-6  col-lg-4">'+
						'  <input class="customCheckbox otg_var" type="checkbox" id="'+buildIDTag(msgTp,'check',msgID)+'" disabled>'+
						'  <label class="labelForCustomCheckbox" id="'+buildIDTag(msgTp,msgID)+'" for="'+buildIDTag(msgTp,'check',msgID)+'"></label>'+
						' </div>';
				}	
				html += '</div>';
			});
			html += '</div>'+
				'<div class="hr"></div>';
			// Info messages in two columns	
			html += '<div class="container-fluid">';
			html += '<div class="row">'; 
			$.each(otgjsInfoMsgLayout, function (key,row){ 
				var msgNr = row[0];
				html += '<div class="col-xs-12 col-md-6">'+
					'<label class="otg_var" id="'+buildIDTag('msg',msgNr)+'"></label>'+
					'<label class="otg_var" id="'+buildIDTag('msgval',msgNr)+'" style="position: absolute; left: 250px; width: 50px; text-align: right;"></label>'+
					'<label class="otg_var" id="'+buildIDTag('msgunit',msgNr)+'" style="position: absolute; left: 305px;"></label>';
				if (otgjsMonitorBars > 0 && row[2] !== null) {
					html += '<label class="otg_progress" style="position: absolute; left: 253px;"><div class="otg_progress-bar" id="'+buildIDTag('msgbar',msgNr)+'"></div></label>';
				}
				html += '</div>';
			});
			html += '</div>'+ // end of row
				'</div>'+
				'<div class="hr"></div>';
			// Error status in four columns	
			html += '<div class="container-fluid">'+
				' <div class="row" style="margin-bottom: 5px; height: 20px; line-height: 20px;">';
			for (var i=0; i<4; i++) {
				html += '<div class="col-xs-6 col-md-3">'+
					' <label class="otg_err" id="'+buildIDTag('err',i)+'" onClick="'+_MOD_PREFIX+'.ResetError('+deviceID+','+i+')" title="Click to reset Error 0'+(i+1)+'"></label>'+
					' &nbsp;&nbsp;<label class="otg_err" id="'+buildIDTag('errval',i)+'"></label>'+
					'</div>';
			}
			html += '</div></div>';
			
			api.setCpanelContent(html);
			if (otgjsMessage === undefined) {
				getInfo(deviceID, _SID, 'GetMessages', otgjsMonitorConfig);
			} else {
				otgjsMonitorConfig(deviceID, otgjsMessage);
			}
        } catch (e) {
            Utils.logError('Error in '+_MOD_PREFIX+'.Monitor(): ' + e);
        }
	}

	// On click of error text reset the count to zero
	function _ResetError(deviceID, n) {
		api.performLuActionOnDevice(deviceID, _SID, "ResetErrorCount", {'Index': n+1});
	}

	function _DisplayMonitor(deviceID) {
		// Keep updating while we are on this tab
		if (document.getElementById(buildIDTag('msg',otgjsInfoMsgLayout[0][0])) !== null) {
			// Get the state of the device
			var deviceObj = api.getDeviceObject(deviceID);
			// Update flag and fault status
			$.each(otgjsInfoLayout, function (key,row){ 
				for (var j=0; j<3; j++) {
					var msgID = row[j];
					var msgTp = (j===2 ? 'fault' : 'flag');
					var msgRef = (j===2 ? 5 : 0);
					var msg = otgjsMessage[msgRef].flags[msgID];
					var val = varGet(deviceID, msg['var']);
					$(buildIDRef(msgTp,'check',msgID)).prop("checked", val == "1");
				}	
			});
			// Update message values
			$.each(otgjsInfoMsgLayout, function (key,row) { 
				var msgNr = row[0];
				var txt = document.getElementById(buildIDTag('msg',msgNr));
				var elem = document.getElementById(buildIDTag('msgval',msgNr));
				var unit = document.getElementById(buildIDTag('msgunit',msgNr));
				var bar = document.getElementById(buildIDTag('msgbar',msgNr));
				var msg = otgjsMessage[msgNr];
				var msgVar = msg['var'];
				if (typeof(msgVar) == 'object') {
					msgVar = row[1];
				}
				var val = varGet(deviceID, msgVar);
				if ((val == null || val == "") && elem.style.color == "") {
					txt.style.color = elem.style.color = unit.style.color = '#DDDDDD';
					elem.innerHTML = '???';
					if (bar != null) { bar.style.width = '0%'; }
				} else if (val != null && val != "") {
					if (elem.style.color != "") {
						txt.style.color = elem.style.color = unit.style.color = '';
					}
					if (val == elem.innerHTML) {
						elem.style.fontWeight = 'normal';
					} else {
						elem.style.fontWeight = 'bold';
						elem.innerHTML = val;
						if (bar != null) {
							var min = row[2];
							var max = row[3];
							if (typeof(max) == 'string') {
								max = parseFloat(varGet(deviceID, otgjsMessage[max]['var']));
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
			});
			// Update error count
			var val = varGet(deviceID, "Errors");
			var val_a = val.split(',');
			for (var i=0; i<val_a.length; i++) {
				$(buildIDRef('errval',i)).html(val_a[i]);
			}
			setTimeout(_MOD_PREFIX+".DisplayMonitor("+deviceID+")", 2000);
		}
	}

	function otgjsMonitorConfig(deviceID, result) {
		otgjsMessage = result;
		// Add flag and fault labels
		$.each(otgjsInfoLayout, function (key,row){ 
			for (var j=0; j<3; j++) {
				var msgID = row[j];
				var msgTp = (j===2 ? 'fault' : 'flag');
				var msgRef = (j===2 ? 5 : 0);
				var msg = otgjsMessage[msgRef].flags[msgID];
				$(buildIDRef(msgTp,msgID)).html(msg.txt);
			}	
		});
		// Add message labels
		$.each(otgjsInfoMsgLayout, function (key,row){ 
			var msgNr = row[0];
			var msg = otgjsMessage[msgNr];
			var txt = msg.txt;
			var n = txt.search(/\([^\)]+\)/);
			var unit = "";
			if (n > 0) {
				unit = txt.substring(n+1, txt.length-1).replace('°', '&deg;');
				txt = txt.substr(0, n-1);
			}
			var sub = row[1];
			if (sub != null && sub != '') {
				var n = txt.search("&");
				if (sub == 'lb') { txt = txt.substr(n+1); } else { txt = txt.substr(0, n-1); }
			}
			$(buildIDRef('msg',msgNr)).html(txt);
			$(buildIDRef('msgunit',msgNr)).html(unit);
		});
		// Add error labels
		for (var i=0; i<4; i++) {
			$(buildIDRef('err',i)).html("Error 0"+(i+1)+":");
		}
		_DisplayMonitor(deviceID);
	}

	//--------
	// Eco tab
	function _Eco() {
		try{
			var deviceID = api.getCpanelDeviceId();
			var deviceList = api.getListOfDevices();
			var yesNo = [{value:'',label:'N/A'},{value:'1',label:'Yes'}];
			var doors = [];
			// Find door/window sensors
			$.each(deviceList,function(key, dev) {
				if (dev.category_num == 4 && dev.subcategory_num == 1) {
					doors.push({'value':dev.id,'label':dev.name});
				}
			});
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
			var html = '<div class="deviceCpanelSettingsPage">'+
				'<h4>Default Eco mode options</h4>'+
				htmlAddPulldown(deviceID, 'Change domestic hot water', 'PluginEcoDHW', dhwOptions)+
				htmlAddPulldown(deviceID, 'Change room setpoint', 'PluginEcoTemp', tempOptions)+
			// Away Eco
				'<h4>Eco options when House Mode is Away</h4>'+
				htmlAddPulldown(deviceID, 'Change domestic hot water', 'PluginArmedAwayDHW', dhwOptions)+
				htmlAddPulldown(deviceID, 'Change room setpoint', 'PluginArmedAwayTemp', tempOptions);

			// Open Eco
			html += '<h4>Eco options when a door/window is open</h4>';
			if (doors.length !== 0) {
				html += htmlAddPulldownMultiple(deviceID, 'Select door/window devices', 'PluginDoorWindowDevices', doors)+
					htmlAddPulldown(deviceID, 'Change room setpoint', 'PluginDoorWindowTemp', tempOptions)+
					htmlAddPulldown(deviceID, 'Option: only when it is open for more than', 'PluginDoorWindowMinutes', minutes);
				var outsideTemp = varGet(deviceID, "OutsideTemperature");
				if (outsideTemp !== undefined) {
					html += htmlAddPulldown(deviceID, 'Option: only when it is colder outside than inside', 'PluginDoorWindowOutside', yesNo);
				}
			} else {
				html += htmlAddLabel('<i>No door sensor found.</i><br>');
			}
			html += htmlAddButton(deviceID, 'Save Changes', 'Eco_UpdateSettings')+
				'</div>';
			api.setCpanelContent(html);
        } catch (e) {
            Utils.logError('Error in '+_MOD_PREFIX+'.Eco(): ' + e);
        }
	}

	function _Eco_UpdateSettings(deviceID) {
		varSet(deviceID,'PluginEcoDHW',htmlGetPulldownSelection(deviceID, 'PluginEcoDHW'));
		varSet(deviceID,'PluginEcoTemp',htmlGetPulldownSelection(deviceID, 'PluginEcoTemp'));
		varSet(deviceID,'PluginArmedAwayDHW',htmlGetPulldownSelection(deviceID, 'PluginArmedAwayDHW'));
		varSet(deviceID,'PluginArmedAwayTemp',htmlGetPulldownSelection(deviceID, 'PluginArmedAwayTemp'));
		var dwVal = htmlGetPulldownSelection(deviceID, 'PluginDoorWindowDevices');
		if (dwVal != -1) { 
			varSet(deviceID,'PluginDoorWindowDevices',dwVal);
			varSet(deviceID,'PluginDoorWindowTemp',htmlGetPulldownSelection(deviceID, 'PluginDoorWindowTemp'));
			varSet(deviceID,'PluginDoorWindowMinutes',htmlGetPulldownSelection(deviceID, 'PluginDoorWindowMinutes'));
			varSet(deviceID,'PluginDoorWindowOutside',htmlGetPulldownSelection(deviceID, 'PluginDoorWindowOutside'));
		}	
		application.sendCommandSaveUserData(true);
		doReload(deviceID);
		setTimeout(function() {
			showBusy(false);
			try {
				api.ui.showMessagePopup("Settings updated, Vera restarting.",0);
			}
			catch (e) {
				myInterface.showMessagePopup("Settings updated, Vera restarting.",0); // ALTUI
			}
		}, 3000);	
	}
	
	//------------------
	// Hardware tab: OTG hardware configuration
	function _Hardware() {
		var deviceID = api.getCpanelDeviceId();
		if (otgjsConfig === undefined) {
			getInfo(deviceID, _SID, 'GetConfiguration', otgjsHardwareConfig);
		} else {
			otgjsHardwareConfig(deviceID, otgjsConfig);
		}
	}

	function otgjsHardwareConfig(deviceID, result) {
		otgjsConfig = result;
		try {
			var showConfig = ['GW', 'REF', 'ITR', 'ROF', 'GPIO', 'LED'];
			var html = '<div class="deviceCpanelSettingsPage">'+
				'<h4>Gateway configuration</h4>';
			$.each(showConfig, function(key, elem) {
				if (otgjsConfig[elem] !== undefined) {
					var list = [];
					for (prop in otgjsConfig[elem].tab) {
						list.push({ 'value':prop,'label':otgjsConfig[elem].tab[prop].txt });
					}
					if (otgjsConfig[elem].cnt === undefined) {
						html += htmlAddPulldown(deviceID, otgjsConfig[elem].txt, otgjsConfig[elem].var, list);
					} else {
						for (var j=0; j<otgjsConfig[elem].cnt; j++){
							html += htmlAddPulldown(deviceID, elem+' '+String.fromCharCode(65+j)+' function', otgjsConfig[elem].var+j, list);
						}
					}
				}
			});
			html += htmlAddButton(deviceID, 'Save Changes', 'Hardware_UpdateSettings')+
				'</div>';
			api.setCpanelContent(html);
        } catch (e) {
            Utils.logError('Error in '+_MOD_PREFIX+'.Hardware(): ' + e);
        }
	}

	function _Hardware_UpdateSettings(deviceID) {
		var showConfig = ['GW', 'REF', 'ITR', 'ROF', 'GPIO', 'LED'];
		$.each(showConfig, function(key, elem) {
			if (otgjsConfig[elem] !== undefined) {
				if (otgjsConfig[elem].cnt === undefined) {
					varSet(deviceID,otgjsConfig[elem].var,htmlGetPulldownSelection(deviceID, otgjsConfig[elem].var));
				} else {
					for (var j=0; j<otgjsConfig[elem].cnt; j++){
						varSet(deviceID,otgjsConfig[elem].var+j,htmlGetPulldownSelection(deviceID, otgjsConfig[elem].var+j));
					}
				}
			}
		});
		application.sendCommandSaveUserData(true);
		doReload(deviceID);
		setTimeout(function() {
			showBusy(false);
			try {
				api.ui.showMessagePopup("Settings updated, Vera restarting.",0);
			}
			catch (e) {
				myInterface.showMessagePopup("Settings updated, Vera restarting.",0); // ALTUI
			}
		}, 3000);	
	}

	//-------------
	// Settings tab: plugin configuration
	function _Settings() {
		var deviceID = api.getCpanelDeviceId();
		if (otgjsMessage === undefined) {
			getInfo(deviceID, _SID, 'GetMessages', otgjsSettingsConfig);
		} else {
			otgjsSettingsConfig(deviceID, otgjsMessage);
		}
	}

	function otgjsSettingsConfig(deviceID, result) {
		otgjsMessage = result;
		try {
			var deviceObj = api.getDeviceObject(deviceID);
			var ip = !!deviceObj.ip ? deviceObj.ip : '';
			var deviceList = api.getListOfDevices();
			// Make list of temerature sensors; exclude our own
			var tempSensors = [{'value':'','label':'None'}];
			var humiditySensors = [{'value':'','label':'None'}];
			var childMsg = [];
			$.each(deviceList, function(key, dev) {
				if (dev.category_num == 17 && dev.id_parent != deviceID) {
					tempSensors.push({ 'value':dev.id,'label':dev.name });
				} else if (dev.category_num == 16) {
					humiditySensors.push({ 'value':dev.id,'label':dev.name });
				}
			});
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
			var html = '<div class="deviceCpanelSettingsPage">'+
				'<h4>Plugin options</h4>';
			if (deviceObj.commUse) {
				html += htmlAddPulldown(deviceID,'Communicate using UART', '', null);
			} else if (deviceObj.ip) {
				html += htmlAddInput(deviceID, 'Communicate using IP', 20, 'IPAddress', _SID, ip);
			}
			html += htmlAddPulldown(deviceID, 'Generate debug logging & files', 'PluginDebug', onOff);
			if (tempSensors.length > 0) {
				html += htmlAddPulldown(deviceID, 'Outside temperature sensor', 'PluginOutsideSensor', tempSensors);
			}
			if (humiditySensors.length > 0) {
				html += htmlAddPulldown(deviceID, 'Room humidity sensor', 'PluginHumiditySensor', humiditySensors);
			}
			html += htmlAddPulldownMultiple(deviceID, 'Use child device for temperature', 'PluginHaveChildren', childMsg)+
				htmlAddPulldown(deviceID, 'Create child devices embedded', 'PluginEmbedChildren', yesNo)+
				htmlAddPulldown(deviceID, 'Show monitor bar indicator', 'PluginMonitorBars', bars)+
				htmlAddPulldown(deviceID, 'Automatically update the gateway clock', 'PluginUpdateClock', clock)+
				htmlAddButton(deviceID, 'Save Changes', 'Settings_UpdateSettings')+
				'</div>';
			api.setCpanelContent(html);
        } catch (e) {
            Utils.logError('Error in '+_MOD_PREFIX+'.Settings(): ' + e);
        }
	}
	function _Settings_UpdateSettings(deviceID) {
		varSet(deviceID,'PluginDebug',htmlGetPulldownSelection(deviceID, 'PluginDebug'));
		var osVal = htmlGetPulldownSelection(deviceID, 'PluginOutsideSensor');
		if (osVal != -1) { varSet(deviceID,'PluginOutsideSensor',osVal); }
		var hmVal = htmlGetPulldownSelection(deviceID, 'PluginHumiditySensor');
		if (osVal != -1) { varSet(deviceID,'PluginHumiditySensor',hmVal); }
		varSet(deviceID,'PluginHaveChildren',htmlGetPulldownSelection(deviceID, 'PluginHaveChildren'));
		varSet(deviceID,'PluginEmbedChildren',htmlGetPulldownSelection(deviceID, 'PluginEmbedChildren'));
		varSet(deviceID,'PluginMonitorBars',htmlGetPulldownSelection(deviceID, 'PluginMonitorBars'));
		varSet(deviceID,'PluginUpdateClock',htmlGetPulldownSelection(deviceID, 'PluginUpdateClock'));
		var ipa = htmlGetElemVal(deviceID, 'IPAddress');
		if (ipa != '') { api.setDeviceAttribute(deviceID, 'ip', ipa); }
		application.sendCommandSaveUserData(true);
		doReload(deviceID);
		setTimeout(function() {
			showBusy(false);
			try {
				api.ui.showMessagePopup("Settings updated, Vera restarting.",0);
			}
			catch (e) {
				myInterface.showMessagePopup("Settings updated, Vera restarting.",0); // ALTUI
			}
		}, 3000);	
	}

	//------------------
	// Generic functions

	// Update variable in user_data and lu_status
	function varSet(deviceID, varID, varVal, sid) {
		if (varVal === -1) { return; }
		if (typeof(sid) == 'undefined') { sid = _SID; }
		api.setDeviceStateVariablePersistent(deviceID, sid, varID, varVal);
	}
	// Get variable value. When variable is not defined, this new api returns false not null.
	function varGet(deviceID, varID, sid) {
		try {
			if (typeof(sid) == 'undefined') { sid = _SID; }
			var res = api.getDeviceState(deviceID, sid, varID);
			if (res !== false && res !== null && res !== 'null' && typeof(res) !== 'undefined') {
				return res;
			} else {
				return '';
			}	
        } catch (e) {
            return '';
        }
	}


	//------------------
	// HTML formatting functions

	// Build tag we use for the id= attribute and for referencing it
	function buildIDTag() {
		var _tg = _DIV_PREFIX;
		for (var i=0; i < arguments.length; i++) {
			_tg += arguments[i];
		}
		return _tg;
	}
	function buildIDRef() {
		var _tg = '#'+_DIV_PREFIX;
		for (var i=0; i < arguments.length; i++) {
			_tg += arguments[i];
		}
		return _tg;
	}
	

	// Standard update for  plug-in pull down variable. We can handle multiple selections.
	function htmlGetPulldownSelection(di, vr) {
		try {
			var value = $(buildIDRef(vr,di)).val() || [];
			return (typeof value === 'object')?value.join():value;
        } catch (e) {
            return -1;
        }
	}

	// Get the value of an HTML input field
	function htmlGetElemVal(di,elID) {
		var res;
		try {
			res=$(buildIDRef(elID,di)).val();
		}
		catch (e) {	
			res = '';
		}
		return res;
	}

	// Add standard text label
	function htmlAddLabel(lb) {
		return '<div class="pull-left inputLabel">'+lb+'</div>';
	}
	
	// Add a label and multiple selection
	function htmlAddPulldownMultiple(di, lb, vr, values) {
		try {
			var selVal = varGet(di, vr);
			var selected = [];
			if (selVal !== '') {
				selected = selVal.split(',');
			}
			var html = '<div id="'+buildIDTag(vr,di)+'_div" class="clearfix labelInputContainer">\
				<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>\
				<div class="pull-left">\
				<select id="'+buildIDTag(vr,di)+'" multiple>';
			$.each(values, function(key, val) {
				var isSel = '';
				$.each(selected, function(key, sel) {
					isSel = (val.value==sel?'selected':'');
				});	
				html += '<option value="'+val.value+'" '+((val.value==selVal)?'selected':'')+'>'+val.label+'</option>';
			});
			html += '</select></div></div>';
			return html;
		} catch (e) {
			Utils.logError(_MOD_PREFIX+': htmlAddPulldownMultiple(): ' + e);
		}
	}

	// Add a label and pulldown selection
	function htmlAddPulldown(di, lb, vr, values) {
		try {
			var selVal = varGet(di, vr);
			var html = '<div id="'+buildIDTag(vr,di)+'_div" class="clearfix labelInputContainer">\
				<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>\
				<div class="pull-left customSelectBoxContainer">\
				<select id="'+buildIDTag(vr,di)+'" class="customSelectBox">';
			$.each(values, function(key, val) {
				html += '<option value="'+val.value+'" '+((val.value==selVal)?'selected':'')+'>'+val.label+'</option>';
			});
			html += '</select></div></div>';
			return html;
		} catch (e) {
			Utils.logError(_MOD_PREFIX+': htmlAddPulldown(): ' + e);
			return '';
		}
	}
	// Add a standard input for a plug-in variable.
	function htmlAddInput(di, lb, si, vr, sid, df) {
		var val = (typeof df != 'undefined') ? df : varGet(di,vr,sid);
		var html = '<div id="'+buildIDTag(vr,di)+'_div" class="clearfix labelInputContainer" >\
					<div class="pull-left inputLabel" style="width:280px;">'+lb+'</div>\
					<div class="pull-left">\
						<input class="customInput" size="'+si+'" id="'+buildIDTag(vr,di)+'" type="text" value="'+val+'">\
					</div>\
					</div>';
		return html;
	}
	// Add a Save Settings button
	function htmlAddButton(di, lb, cb) {
		html = '<div class="cpanelSaveBtnContainer labelInputContainer clearfix">\
			<input class="vBtn pull-right" type="button" value="'+lb+'" onclick="'+_MOD_PREFIX+'.'+cb+'(\''+di+'\');"></input>\
			</div>';
		return html;
	}

	// Show/hide the interface busy indication.
	function showBusy(busy) {
		if (busy === true) {
			try {
					api.ui.showStartupModalLoading(); 
				} catch (e) {
					myInterface.showStartupModalLoading(); // For ALTUI support.
				}
		} else {
			try {
				api.ui.hideModalLoading(true);
			} catch (e) {
				myInterface.hideModalLoading(true); // For ALTUI support
			}	
		}
	}

	function doReload(deviceID) {
		api.performLuActionOnDevice(0, "urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {});
	}


	// request and handle information from Vera async.
	function getInfo(device, sid, what, func) {
		var result;
		var tmstmp = new Date().getTime(); // To avoid caching issues, mainly IE.
		try {
			var requestURL = api.getDataRequestURL(); 
		} catch (e) {
			var requestURL = data_request_url;
		}
		(function() {
			$.getJSON(requestURL, {
				id: 'lr_'+what+device,
				serviceId: sid,
				DeviceNum: device,
				timestamp: tmstmp,
				output_format: 'json'
			})
			.done(function(data) {
				func(device, data);
			})	
			.fail(function(data) {
				func(device, "Failed to get data from OTG.");
			});
		})();
	}

	// Expose interface functions
    myModule = {
		// Internal for panels
        uuid: _uuid,
        init: _init,
        onBeforeCpanelClose: _onBeforeCpanelClose,
		ResetError: _ResetError,
		Eco_UpdateSettings: _Eco_UpdateSettings,
		Hardware_UpdateSettings: _Hardware_UpdateSettings,
		Settings_UpdateSettings: _Settings_UpdateSettings,
		DisplayMonitor : _DisplayMonitor,
		
		// For JSON calls
        Settings: _Settings,
		Monitor: _Monitor,
        Eco: _Eco,
        Hardware: _Hardware
    };
    return myModule;
})(api);
