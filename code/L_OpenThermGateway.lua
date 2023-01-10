--[[
	Module L_OpenThermGateway.lua

	Written by nlrb, modified for UI7 and ALTUI by Rene Boer
	
	V1.18	12 January 2023
	
	V1.18 Changes:
			Added urn:upnp-org:serviceId:TemperatureSensor1 CurrentSetpoint and SetpointTarget for better compatibility.

	V1.17 Changes:
			Added commands map for firmware 5 & 6
			Updated ref voltage map to show PIC16F1847 values as well.
			Fixed EOM Fault code display, and hardware settings for LEDs and GPIO for UI7 and ALTUI.
			Fix for set clock command.
			Added OpenTherm 2.3 messages for solar (not tested). Thanks to https://github.com/rvdbreemen
			
	V1.16 Changes:
			CustomModeConfiguration has been corrected in 7.30, adapting for change
	
	V1.15 Changes:
			Check on watched devices to be still existing. When obsolete plugin can response to any device changes.
			
	V1.13 Changes:
			Fixed House Mode Vacation eco mode monitoring.
			
	V1.12 Changes:
			Fixed incorrect watch settings on variables. Caused many watch triggers and maybe instability.
			Updated for new ALTUI plugin registration API.

	V1.11 Changes:
			Renamed string:split function to to string:otg_split as it caused issues on openLuup. It seems all code share the same name space.
			Set functions to local as much as possible to avoid similar issues on other named functions.
	
	V1.10 Changes:
			Use luup.att_get to get the OTG IP address and port to use.
			
	V1.9 Changes:
			Minor change to string:split function to avoid code errors causing ALTUI to fail on openLuup.
	
	V1.8 Changes:
			Added support for presets House Modes dashboard.
			Restored Alarm Pannel options for UI7. You now can set Eco or Normal in House Modes dashboard and it uese the default Eco settings for that.
			
	V1.7 Changes:
			Added a watch to RemoteOverrideRoomSetpoint to keep override temp in case House mode is vacation.
			
	V1.6 Changes:
			Some clean ups.
			Proper support of the Disabled attribute.
			Support for more scene and notification triggers
			Use of dkjson
			Tested for openLuup. Need to install package lua-bitop (sudo apt-get install lua-bitop)
			
	V1.5 Changes:
			For UI7. In Vacation mode the command TC= is used, in Away mode TT=. This way the thermostat program can warm up the house for the evening when away for the day.
			Note: not all thermostats keep the setpoint with TC=, some have the program overwrite anyway. An update for that situation is in the planning.

	V1.4 Changes:
			Uptimized for UI7 and ALTUI.
			Added 60 seconds polling of Home / Away status instead of monitoring an alarm pannel status. When Away/Vacation ECO options are used, when Home restored.
			Use of otg. variable container to reduce number of variabled (Vera can handle up to 60, but less is better)
			
]]

module("L_OpenThermGateway", package.seeall)

local bitw = require("bit")      -- needed for bit-wise operations
local socket = require("socket") -- needed for accurate timing
local json = require("dkjson") 	 -- Needed for converting tables to JSON strings.

-------------------------------------------------------------
-- Monitor and control the OpenTherm Gateway via Mios Vera --
-------------------------------------------------------------
--- QUEUE STRUCTURE ---
local Queue = {}
function Queue.new()
   return {first = 0, last = -1}
end

function Queue.push(list, value)
   local last = list.last + 1
   list.last = last
   list[last] = value
end
    
function Queue.pop(list)
   local first = list.first
   if first > list.last then return nil end
   local value = list[first]
   list[first] = nil -- to allow garbage collection
   list.first = first + 1
   return value
end

function Queue.len(list)
   return list.last - list.first + 1
end
 
local otg = {  -- Plugin data
	PLUGIN_VERSION = "1.18",
	Description = "OpenThermGateway",
	--- SERVICES ---
	GATEWAY_SID    = "urn:otgw-tclcode-com:serviceId:OpenThermGateway1",
	TEMP_SENS_SID  = "urn:upnp-org:serviceId:TemperatureSensor1",
	HVAC_STATE_SID = "urn:micasaverde-com:serviceId:HVAC_OperatingState1",
	HVAC_USER_SID  = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1",
	TEMP_SETP_SID  = "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat",
	SW_PWR_SID     = "urn:upnp-org:serviceId:SwitchPower1",
	HA_DEV_SID     = "urn:micasaverde-com:serviceId:HaDevice1",
	PARTITION_SID  = "urn:micasaverde-com:serviceId:AlarmPartition2",
	DOOR_SENS_SID  = "urn:micasaverde-com:serviceId:SecuritySensor1",
	HUMY_SENS_SID  = "urn:micasaverde-com:serviceId:HumiditySensor1",
	ALTUI_SID      = "urn:upnp-org:serviceId:altui1",

	--- DEVICES ---
	Device,
	ChildDevice_t = {},

	--- DYNAMIC VALUES ---
	MajorVersion = 3,
	ErrorCnt_t = {},
	PrevMode = nil,
	LastStatus = 0,
	MsgSupported_t = {},
	MsgCreateChild_t = {},
	GatewayMode = false,
	ExpectingResponse = false,
	LastResponse = -1,
	SendQueue = Queue.new(),
	ResponseQueue = Queue.new(),
	ui7Check = false,
	Disabled = false,
	MinimalSetPoint = 14,
	
	--- DEBUGGING ---
	LogDebug = 0,
	LogPath = "/tmp/log/cmh/",
	LogFilename = "<id>_otg_msg.txt",

	--- SYSTEM TABLES ---
	UPnPDevice_t = {
		TEMP = { 
			sid = "urn:upnp-org:serviceId:TemperatureSensor1",
			imp = "D_TemperatureSensor1.xml",
			dev = "urn:schemas-micasaverde-com:device:TemperatureSensor:1",
			var = "CurrentTemperature"
		},
		GEN  = {
			sid = "urn:micasaverde-com:serviceId:GenericSensor1",
			imp = "D_GenericSensor1.xml",
			dev = "urn:schemas-micasaverde-com:device:GenericSensor:1",
			var = "CurrentLevel"
		}
	},
	ClockSync_t = {
		NONE = 0, TIME = 1, DATE = 2, YEAR = 3
	},
	DebugLevel_t = {
		FILE = 1, INFO = 2, MSG = 4, FLAG = 8
	},

	-- Make sure commands are issued in the right order (the lua table otgConfig_t does not have an order)
	Startup_t = { "GW", "LED", "ITR", "ROF", "REF", "SETB", "HOT", "GPIO", "PWR" },
	
	-- OpenTherm Gateway operating modes
	GatewayMode_t = {
		[0] = { txt = "Monitor" },
		[1] = { txt = "Gateway" }
	},
	
	-- OpenTherm Gateway LED functions
	LedFunction_t = {
		R = { txt = "Receiving an OpenTherm message from the thermostat or boiler" },
		X = { txt = "Transmitting an OpenTherm message to the thermostat or boiler" },
		T = { txt = "Transmitting or receiving a message on the master interface" },
		B = { txt = "Transmitting or receiving a message on the slave interface" },
		O = { txt = "Remote setpoint override is active" },
		F = { txt = "Flame is on", var = "FlameStatus" },
		H = { txt = "Central heating is on", var = "CHMode" },
		W = { txt = "Hot water is on", var = "DHWMode" },
		C = { txt = "Comfort mode (Domestic Hot Water Enable) is on", var = "DHWEnabled" },
		E = { txt = "Transmission error has been detected", var = "Errors" },
		M = { txt = "Boiler requires maintenance", var = "DiagnosticEvent" },
		P = { txt = "Thermostat requests a raised power level" }
	},

	-- OpenTherm Gateway GPIO configuration
	GPIOFunction_t = {
		[0] = { txt = "None"},
		[1] = { txt = "Ground (0V)"},
		[2] = { txt = "Vcc (5V)"},
		[3] = { txt = "LED E"},
		[4] = { txt = "LED F"},
		[5] = { txt = "Setback (low)"},
		[6] = { txt = "Setback (high)"},
		[7] = { txt = "Temperature sensor"},
		[8] = { txt = "Activate DHW blocking when pulled low (PIC16F1847 only)" }
	},

	-- OpenTherm Gateway signal transition checking
	IgnoreTrans_t = {
		[0] = { txt = "Check" },
		[1] = { txt = "Ignore" }
	},

	-- OpenTherm Gateway reference voltage
	RefVoltage_t = {
		[0] = { txt = "0.625V/0.832V" },
		[1] = { txt = "0.833V/0.960V" },
		[2] = { txt = "1.042V/1.088V" },
		[3] = { txt = "1.250V/1.216V" },
		[4] = { txt = "1.458V/1.344V" },
		[5] = { txt = "1.667V/1.472V" },
		[6] = { txt = "1.875V/1.600V" },
		[7] = { txt = "2.083V/1.728V" },
		[8] = { txt = "2.292V/1.856V" },
		[9] = { txt = "2.500V/1.984V" },
	},

	-- OpenTherm Gateway domestic hot water setting
	DHWsetting_t = {
		[0] = { txt = "Off" },
		[1] = { txt = "On (comfort mode)" },
		A  = { txt = "Thermostat controlled" }
	},

	-- OpenTherm Gateway message types
	MsgInitiator_t = {
		A = "Answer", B = "Boiler", R = "Request", T = "Thermostat"
	},

	-- OpenTherm message type
	MsgType_t = {
		[0] = "Read-Data", [1] = "Write-Data", [2] = "Invalid-Data", [3] = "-reserved-", 
		[4] = "Read-Ack", [5] = "Write-Ack", [6] = "Data-Invalid", [7] = "Unknown-DataId"
	},

	-- OpenTherm status flags [ID 0: Master status (HB) & Slave status (LB)]
	StatusFlag_t = {
		[0x0100] = { txt = "Central heating enable", var = "StatusCHEnabled" },
		[0x0200] = { txt = "Domestic hot water enable", var = "StatusDHWEnabled" },
		[0x0400] = { txt = "Cooling enable", var = "StatusCoolEnabled" },
		[0x0800] = { txt = "Outside temp. comp. active", var = "StatusOTCActive" },
		[0x1000] = { txt = "Central heating 2 enable", var = "StatusCH2Enabled" },
		[0x2000] = { txt = "Summer/winter mode", var = "StatusSummerWinter" },
		[0x4000] = { txt = "Domestic hot water blocking", var = "StatusDHWBlocked" },
		[0x0001] = { txt = "Fault indication", var = "StatusFault" }, -- no fault/fault
		[0x0002] = { txt = "Central heating mode", var = "StatusCHMode" }, -- not active/active
		[0x0004] = { txt = "Domestic hot water mode", var = "StatusDHWMode" }, -- not active/active
		[0x0008] = { txt = "Flame status", var = "StatusFlame" }, -- flame off/on
		[0x0010] = { txt = "Cooling status", var = "StatusCooling" }, -- not active/active
		[0x0020] = { txt = "Central heating 2 mode", var = "StatusCH2Mode" }, -- not active/active
		[0x0040] = { txt = "Diagnostic indication", var = "StatusDiagnostic" } -- no diagnostics/diagnostics event
	},

	-- OpenTherm Master configuration flags [ID 2: master config flags (HB)]
	MasterConfigFlag_t = {
		[0x0100] = { txt = "Smart Power", var = "ConfigSmartPower" }
	},

	-- OpenTherm Slave configuration flags [ID 3: slave config flags (HB)]
	SlaveConfigFlag_t = {
		[0x0100] = { txt = "Domestic hot water present", var = "ConfigDHWpresent" },
		[0x0200] = { txt = "Control type (modulating on/off)", var = "ConfigControlType" },
		[0x0400] = { txt = "Cooling supported", var = "ConfigCooling" },
		[0x0800] = { txt = "Domestic hot water storage tank", var = "ConfigDHW" },
		[0x1000] = { txt = "Master low-off & pump control allowed", var = "ConfigMasterPump" },
		[0x2000] = { txt = "Central heating 2 present", var = "ConfigCH2" }
	},

	-- OpenTherm fault flags [ID 5: Application-specific fault flags (HB)]
	FaultFlag_t = {
		[0x0100] = { txt = "Service request", var = "FaultServiceRequest" },
		[0x0200] = { txt = "Lockout-reset", var = "FaultLockoutReset" },
		[0x0400] = { txt = "Low water pressure", var = "FaultLowWaterPressure" },
		[0x0800] = { txt = "Gas/flame fault", var = "FaultGasFlame" },
		[0x1000] = { txt = "Air pressure fault", var = "FaultAirPressure" },
		[0x2000] = { txt = "Water over-temperature", var = "FaultOverTemperature" }
	},

	-- OpenTherm remote flags [ID 6: Remote parameter flags (HB)]
	RemoteFlag_t = {
		[0x0100] = { txt = "DHW setpoint enable", var = "RemoteDHWEnabled" },
		[0x0200] = { txt = "Max. CH setpoint enable", var = "RemoteMaxCHEnabled" },
		[0x0001] = { txt = "DHW setpoint read/write", var = "RemoteDHWReadWrite" },
		[0x0002] = { txt = "Max. CH setpoint read/write", var = "RemoteMaxCHReadWrite" }
	},

	EcoMeasure_t = {
		DECO_DHW = { txt = "Change domestic hot water in Eco mode", state = "EDHW", var = "PED" },
		DECO_TMP = { txt = "Change room setpoint in Eco mode", state = "ETMP", var = "PET" },
		PART_DHW = { txt = "Change domestic hot water when Armed Away", state = "ADHW", var = "AAD", 
			chk = { var = "PluginPartitionDevice", cond = "AWAY" },
		},
		PART_TMP = { txt = "Change room setpoint when Armed Away", state = "ATMP", var = "AAT", 
			chk = { var = "PluginPartitionDevice" , cond = "AWAY" },
		},
		DOOR_TMP = { txt = "Change room setpoint when door is open", state = "DTMP", var = "DWT", 
			chk = { { var = "PluginDoorWindowDevices", cond = "OPEN" }, { var = "PluginDoorWindowOutside", cond = "TEMPOUT" }, { var = "PluginDoorWindowMinutes", cond = "DELAY" } }
		}
	}
}

local otgPluginInit_t = {
   UI7 = { var = "PluginUI7", init = "false" },
   CMC = { var = "CustomModeConfiguration", sid = otg.HA_DEV_SID, init = "Normal;CMDNormal;"..otg.HVAC_USER_SID.."/SetEnergyModeTarget/NewModeTarget=Normal|Eco;CMDEco;"..otg.HVAC_USER_SID.."/SetEnergyModeTarget/NewModeTarget=EnergySavingsMode" },
   MEM = { var = "PluginMemoryUsed", init = "0" },
   VER = { var = "PluginVersion", init = otg.PLUGIN_VERSION, reset = true },
   DBG = { var = "PluginDebug", init = "0" },
   LOG = { var = "PluginLogPath", init = otg.LogPath },
   CHD = { var = "PluginHaveChildren" },
   EMB = { var = "PluginEmbedChildren", init = "1" },
   BAR = { var = "PluginMonitorBars", init = "2" },
   CLK = { var = "PluginUpdateClock", init = "0" },
   OUT = { var = "PluginOutsideSensor" },
   HUM = { var = "PluginHumiditySensor" },
   ECO = { var = "PluginEcoMeasureState" },
   PPD = { var = "PluginPartitionDevice" },
   PED = { var = "PluginEcoDHW" },
   PET = { var = "PluginEcoTemp" },
   AAD = { var = "PluginArmedAwayDHW" },
   AAT = { var = "PluginArmedAwayTemp" },
   DWD = { var = "PluginDoorWindowDevices" },
   DWT = { var = "PluginDoorWindowTemp" },
   DWM = { var = "PluginDoorWindowMinutes" },
   DWO = { var = "PluginDoorWindowOutside" },
   GWM = { var = "GatewayMode" },
   RES = { var = "CommandResponse", reset = true },
   SAV = { var = "EnergyModeStatus", sid = otg.HVAC_USER_SID, init = "Normal" },
   ERR = { var = "Errors", init = "0,0,0,0", reset = true }
}

-- Variable to watch and register handler for; device id filled dynamically
local otgWatchVar_t = {
   ROVR = { src = "", sid = otg.GATEWAY_SID, var = "RemoteOverrideRoomSetpoint", dev = nil },
   TEMP = { src = "PluginOutsideSensor", sid = otg.TEMP_SENS_SID, var = "CurrentTemperature", dev = nil },
   HUMY = { src = "PluginHumiditySensor", sid = otg.HUMY_SENS_SID, var = "CurrentLevel", dev = nil },
   PART = { src = "PluginPartitionDevice", sid = otg.PARTITION_SID, var = "DetailedArmMode", dev = nil },
   DOOR = { src = "PluginDoorWindowDevices", sid = otg.DOOR_SENS_SID, var = "Tripped", dev = nil }
}

-- OpenTherm messages 
local otgMessage_t = {
   [ 0] = { dir = "R-", txt = "Status", val = "flag8", flags = otg.StatusFlag_t },
   [ 1] = { dir = "-W", txt = "Control setpoint (°C)", val = "f8.8", var = "ControlSetpoint", child = "TEMP" },
   [ 2] = { dir = "-W", txt = "Master configuration", val = { hb = "flag8", lb = "u8" }, flags = otg.MasterConfigFlag_t, var = { lb = "MasterMemberId" } },
   [ 3] = { dir = "R-", txt = "Slave configuration", val = { hb = "flag8", lb = "u8" }, flags = otg.SlaveConfigFlag_t, var = { lb = "SlaveMemberId" } },
   [ 4] = { dir = "-W", txt = "Remote command", val = "u8", var = "RemoteCommand" },
   [ 5] = { dir = "R-", txt = "Fault flags & OEM fault code", val = { hb = "flag8", lb = "u8" }, var = { lb = "FaultCode" }, flags = otg.FaultFlag_t },
   [ 6] = { dir = "R-", txt = "Remote parameter flags", val = "flag8", flags = otg.RemoteFlag_t },
   [ 7] = { dir = "-W", txt = "Cooling control signal (%)", val = "f8.8", var = "CoolingControlSignal" },
   [ 8] = { dir = "-W", txt = "Control setpoint central heating 2 (°C)", val = "f8.8", var = "CH2ControlSetpoint", child = "TEMP" },
   [ 9] = { dir = "R-", txt = "Remote override room setpoint (°C)", val = "f8.8", var ="RemoteOverrideRoomSetpoint", child = "TEMP" },
   [10] = { dir = "R-", txt = "Number of transparent slave parameters (TSP) supported by slave", val = "u8", var = { hb = "TSPNumber" } },
   [11] = { dir = "RW", txt = "Index number/value of referred-to transparent slave parameter (TSP)", val = "u8", var = { hb = "TSPIndex", lb = "TSPValue" } },
   [12] = { dir = "R-", txt = "Size of fault history buffer (FHB) supported by slave", val = "u8", var = { hb = "FHBSize" } },
   [13] = { dir = "R-", txt = "Index number/value of referred-to fault history buffer (FHB) entry", val = "u8", var = { hb = "FHBIndex", lb = "FHBValue" } },
   [14] = { dir = "-W", txt = "Max. relative modulation level (%)", val = "f8.8", var = "MaxRelativeModulationLevel" },
   [15] = { dir = "R-", txt = "Max. boiler capacity (kW) and modulation level setting (%)", val = "u8", var = { hb = "MaxBoilerCapacity", lb = "MinModulationLevel" } },
   [16] = { dir = "-W", txt = "Room setpoint (°C)", val = "f8.8", sid = otg.TEMP_SETP_SID, var = "CurrentSetpoint", child = "TEMP" },
   [17] = { dir = "R-", txt = "Relative modulation level (%)", val = "f8.8", var = "RelativeModulationLevel", child = "GEN" },
   [18] = { dir = "R-", txt = "Central heating water pressure (bar)", val = "f8.8", var = "CHWaterPressure", child = "GEN" },
   [19] = { dir = "R-", txt = "Domestic hot water flow rate (litres/minute)", val = "f8.8", var = "DHWFlowRate", child = "GEN" },
   [20] = { dir = "RW", txt = "Day of week & time of day", var = "DayTime" },
   [21] = { dir = "RW", txt = "Date", val = "u8", var = "Date" },
   [22] = { dir = "RW", txt = "Year", val = "u16", var = "Year" },
   [23] = { dir = "-W", txt = "Room setpoint central heating 2 (°C)", val = "f8.8", var = "CH2CurrentSetpoint", child = "TEMP" },
   [24] = { dir = "-W", txt = "Room temperature (°C)", val = "f8.8", sid = otg.TEMP_SENS_SID, var = "CurrentTemperature", child = "TEMP" },
   [25] = { dir = "R-", txt = "Boiler water temperature (°C)", val = "f8.8", var = "BoilerWaterTemperature", child = "TEMP" },
   [26] = { dir = "R-", txt = "Domestic hot water temperature (°C)", val = "f8.8", var = "DHWTemperature", child = "TEMP" },
   [27] = { dir = "R-", txt = "Outside temperature (°C)", val = "f8.8", var = "OutsideTemperature", child = "TEMP" },
   [28] = { dir = "R-", txt = "Return water temperature (°C)", val = "f8.8", var = "ReturnWaterTemperature", child = "TEMP" },
   [29] = { dir = "R-", txt = "Solar storage temperature (°C)", val = "f8.8", var = "SolarStorageTemperature", child = "TEMP" },
   [30] = { dir = "R-", txt = "Solar collector temperature (°C)", val = "f8.8", var = "SolarCollectorTemperature", child = "TEMP" },
   [31] = { dir = "R-", txt = "Flow temperature central heating 2 (°C)", val = "f8.8", var = "CH2FlowTemperature", child = "TEMP" },
   [32] = { dir = "R-", txt = "Domestic hot water 2 temperature (°C)", val = "f8.8", var = "DHW2Temperature", child = "TEMP" },
   [33] = { dir = "R-", txt = "Boiler exhaust temperature (°C)", val = "s16", var = "BoilerExhaustTemperature", child = "TEMP" },
   -- V1.17 start
   [34] = { dir = "R-", txt = "Boiler heat exchanger temperature (°C)", val = "f8.8", var = "BoilerHeatExchangerTemperature", child = "TEMP" },
   [35] = { dir = "R-", txt = "Boiler fan speed and setpoint (rpm)", val = { hb = "u8", lb = "u8" }, var = { lb = "BoilerFanSpeedStatus", lb = "BoilerFanSpeedTarget" } },
   [36] = { dir = "R-", txt = "Electrical current through burner flame (uA)", val = "f8.8", var = "ElectricalCurrentBurnerFlame" },
   [37] = { dir = "R-", txt = "Room temperature for 2nd CH circuit (°C)", val = "f8.8", var = "CH2RoomTemperature", child = "TEMP" },
   [38] = { dir = "R-", txt = "Relative Humidity (%)", val = { hb = "u8", lb = "u8" }, var = { lb = "RelativeHumidity" }, child = "GEN" },
   -- V1.17 end
   [48] = { dir = "R-", txt = "Domestic hot water setpoint boundaries (°C)", val = "s8", var = "DHWBounadries" },
   [49] = { dir = "R-", txt = "Max. central heating setpoint boundaries (°C)", val = "s8", var = "CHBoundaries" },
   [50] = { dir = "R-", txt = "OTC heat curve ratio upper & lower bounds", val = "s8", var = "OTCBoundaries" },
   -- V1.17 start
   [51] = { dir = "R-", txt = "Remote parameter 4 boundaries", val = "s8", var = "RemoteParameter4Boundaries" },
   [52] = { dir = "R-", txt = "Remote parameter 5 boundaries", val = "s8", var = "RemoteParameter5Boundaries" },
   [53] = { dir = "R-", txt = "Remote parameter 6 boundaries", val = "s8", var = "RemoteParameter6Boundaries" },
   [54] = { dir = "R-", txt = "Remote parameter 7 boundaries", val = "s8", var = "RemoteParameter7Boundaries" },
   [55] = { dir = "R-", txt = "Remote parameter 8 boundaries", val = "s8", var = "RemoteParameter8Boundaries" },
   -- V1.17 end
   [56] = { dir = "RW", txt = "Domestic hot water setpoint (°C)", val = "f8.8", var = "DHWSetpoint", child = "TEMP" },
   [57] = { dir = "RW", txt = "Max. central heating water setpoint (°C)", val = "f8.8", var = "MaxCHWaterSetpoint", child = "TEMP" },
   [58] = { dir = "RW", txt = "OTC heat curve ratio (°C)", val = "f8.8", var = "OTCHeatCurveRatio" },
   -- V1.17 start
   [59] = { dir = "RW", txt = "Remote parameter 4", val = "f8.8", var = "RemoteParameter4" },
   [60] = { dir = "RW", txt = "Remote parameter 5", val = "f8.8", var = "RemoteParameter5" },
   [61] = { dir = "RW", txt = "Remote parameter 6", val = "f8.8", var = "RemoteParameter6" },
   [62] = { dir = "RW", txt = "Remote parameter 7", val = "f8.8", var = "RemoteParameter7" },
   [63] = { dir = "RW", txt = "Remote parameter 8", val = "f8.8", var = "RemoteParameter8" },
   -- V1.17 end
   -- OpenTherm 2.3 IDs (70-91) for ventilation/heat-recovery applications
   [70] = { dir = "R-", txt = "Status ventilation/heat-recovery", val = "flag8", var = "VHStatus" },
   [71] = { dir = "-W", txt = "Control setpoint ventilation/heat-recovery", val = "u8", var = { hb = "VHControlSetpoint" } },
   [72] = { dir = "R-", txt = "Fault flags/code ventilation/heat-recovery", val = { hb = "flag8", lb = "u8" }, var = { lb = "VHFaultCode" } },
   [73] = { dir = "R-", txt = "Diagnostic code ventilation/heat-recovery", val = "u16", var = "VHDiagnosticCode" },
   [74] = { dir = "R-", txt = "Config/memberID ventilation/heat-recovery", val = { hb = "flag8", lb = "u8" }, var = { lb = "VHMemberId" } },
   [75] = { dir = "R-", txt = "OpenTherm version ventilation/heat-recovery", val = "f8.8", var = "VHOpenThermVersion" },
   [76] = { dir = "R-", txt = "Version & type ventilation/heat-recovery", val = "u8", var = { hb = "VHProductType", lb = "VHProductVersion" } },
   [77] = { dir = "R-", txt = "Relative ventilation", val = "u8", var = { hb = "RelativeVentilation" }, child = "GEN" },
   [78] = { dir = "RW", txt = "Relative humidity (%)", val = "u8", var = { hb = "RelativeHumidity" }, child = "GEN" },
   [79] = { dir = "RW", txt = "CO2 level", val = "u16", var = "CO2Level", child = "GEN" },
   [80] = { dir = "R-", txt = "Supply inlet temperature (°C)", val = "f8.8", var = "SupplyInletTemperature", child = "TEMP" },
   [81] = { dir = "R-", txt = "Supply outlet temperature (°C)", val = "f8.8", var = "SupplyOutletTemperature", child = "TEMP" },
   [82] = { dir = "R-", txt = "Exhaust inlet temperature (°C)", val = "f8.8", var = "ExhaustInletTemperature", child = "TEMP" },
   [83] = { dir = "R-", txt = "Exhaust outlet temperature (°C)", val = "f8.8", var = "ExhaustOutletTemperature", child = "TEMP" },
   [84] = { dir = "R-", txt = "Actual exhaust fan speed", val = "u16", var = "ExhaustFanSpeed" },
   [85] = { dir = "R-", txt = "Actual inlet fan speed", val = "u16", var = "InletFanSpeed" },
   [86] = { dir = "R-", txt = "Remote parameter settings ventilation/heat-recovery", val = "flag8", var = "VHRemoteParameter" },
   [87] = { dir = "RW", txt = "Nominal ventilation value", val = "u8", var = "NominalVentilation" },
   [88] = { dir = "R-", txt = "TSP number ventilation/heat-recovery", val = "u8", var = { hb = "VHTSPSize" } },
   [89] = { dir = "RW", txt = "TSP entry ventilation/heat-recovery", val = "u8", var = { hb = "VHTSPIndex", lb = "VHTSPValue" } },
   [90] = { dir = "R-", txt = "Fault buffer size ventilation/heat-recovery", val = "u8", var = { hb = "VHFHBSize" } },
   [91] = { dir = "R-", txt = "Fault buffer entry ventilation/heat-recovery", val = "u8", var = { hb = "VHFHBIndex", lb = "VHFHBValue" } },
   -- V1.17 start
   [98] = { dir = "R-", txt = "RF strength and battery level", val = "u8", var = { hb = "RFStrength", lb = "BatteryLevel" } },
   [99] = { dir = "R-", txt = "Operating Mode HC1, HC2/ DHW", val = "u8", var = { hb = "OperatingModeHC1", lb = "OperatingModeHC2_DHW" } },
   -- V1.17 end
   -- OpenTherm 2.2 IDs
   [100] = { dir = "R-", txt = "Remote override function", val = { hb = "flag8", lb = "u8" }, var = { hb = "RemoteOverrideFunction" } },
   -- V1.17 start
   [101] = { dir = "R-", txt = "Solar Storage Master mode", val = { hb = "flag8", lb = "flag8" }, var = { hb = "SolarStorageMasterMode", lb = "SolarStorageSlaveStatus" } },
   [102] = { dir = "R-", txt = "Solar Storage Application-specific flags and OEM fault", val = { hb = "flag8", lb = "u8" }, var = { hb = "SolarStorageASFflags", lb = "SolarStorageOEMErrorCode" } },
   [103] = { dir = "R-", txt = "Solar Storage Slave Config / Member ID", val = { hb = "flag8", lb = "u8" }, var = { hb = "SolarStorageSlaveConfig", lb = "SolarStorageSlaveMemberIDcode" } },
   [104] = { dir = "R-", txt = "Solar Storage product version number and type", val = "u8", var = { hb = "SolarStorageProductVersion", lb = "SolarStorageProductType" } },
   [105] = { dir = "R-", txt = "Solar Storage Number of Transparent-Slave-Parameters supported", val = "u8", var = "SolarStorageTSP" },
   [106] = { dir = "R-", txt = "Solar Storage Index number / Value of referred-to transparent slave parameter", val = "u8", var = { hb = "SolarStorageTSPindex", lb = "SolarStorageTSPvalue" } },
   [107] = { dir = "R-", txt = "Solar Storage Size of Fault-History-Buffer supported by slave", val = "u8", var = "SolarStorageFHBsize" },
   [108] = { dir = "R-", txt = "Solar Storage Index number / Value of referred-to fault-history buffer entry", val = "u8", var = { hb = "SolarStorageFHBindex", lb = "SolarStorageFHBvalue" } },
   [109] = { dir = "R-", txt = "Electricity producer starts", val = "u16", var = "ElectricityProducerStarts" },
   [110] = { dir = "R-", txt = "Electricity producer hours", val = "u16", var = "ElectricityProducerHours" },
   [111] = { dir = "R-", txt = "Electricity production", val = "u16", var = "ElectricityProduction" },
   [112] = { dir = "R-", txt = "Cumulativ Electricity production", val = "u16", var = "CumulativElectricityProduction" },
   [113] = { dir = "RW", txt = "Unsuccessful burner starts", val = "u16", var = "BurnerUnsuccessfulStarts" },
   [114] = { dir = "RW", txt = "Flame signal too low count", val = "u16", var = "FlameSignalTooLow" },
   -- V1.17 end
   [115] = { dir = "R-", txt = "OEM diagnostic code", val = "u16", var = "OEMDiagnosticCode" },
   [116] = { dir = "RW", txt = "Number of starts burner", val = "u16", var = "StartsBurner" },
   [117] = { dir = "RW", txt = "Number of starts central heating pump", val = "u16", var = "StartsCHPump" },
   [118] = { dir = "RW", txt = "Number of starts domestic hot water pump/valve", val = "u16", var = "StartsHDWPump" },
   [119] = { dir = "RW", txt = "Number of starts burner during domestic hot water mode", val = "u16", var = "StartsBurnerDHW" },
   [120] = { dir = "RW", txt = "Number of hours that burner is in operation (i.e. flame on)", val = "u16", var = "HoursBurner" },
   [121] = { dir = "RW", txt = "Number of hours that central heating pump has been running", val = "u16", var = "HoursCHPump" },
   [122] = { dir = "RW", txt = "Number of hours that domestic hot water pump has been running/valve has been opened", val = "u16", var = "HoursDHWPump" },
   [123] = { dir = "RW", txt = "Number of hours that domestic hot water burner is in operation during DHW mode", val = "u16", var = "HoursPumpDHW" },
   [124] = { dir = "-W", txt = "Opentherm version Master", val = "f8.8", var = "MasterOpenThermVersion" },
   [125] = { dir = "R-", txt = "Opentherm version Slave", val = "f8.8", var = "SlaveOpenThermVersion" },
   [126] = { dir = "-W", txt = "Master product version and type", val = "u8", var = { hb = "MasterProductType", lb = "MasterProductVersion" } },
   [127] = { dir = "R-", txt = "Slave product version and type", val = "u8", var = { hb = "SlaveProductType", lb = "SlaveProductVersion" } },
   -- V1.17 start
   [131] = { dir = "RW", txt = "Remeha dF-/dU-codes", val = "u8", var = "RemehadFdUcodes" },
   [132] = { dir = "R-", txt = "Remeha Servicemessage", val = "u8", var = "RemehaServicemessage" },
   [133] = { dir = "R-", txt = "Remeha detection connected SCU’s", val = "u8", var = "RemehaDetectionConnectedSCU" }
   -- V1.17 end
}

local otgConfig_t = {
--   VER = { txt = "Gateway firmware version", var = "FirmwareVersion", rep = "A", ret = "OpenTherm Gateway (.*)", handler = nil },
   VER = { txt = "Gateway firmware version", var = "FirmwareVersion", rep = "A", ret = "OpenTherm Gateway (.*)" },
   GW  = { txt = "Operating mode", tab = otg.GatewayMode_t, var = "GatewayMode", cmd = "GW", rep = "G", ret = "[0|1]"},
   LED = { txt = "Function LED <A>", tab = otg.LedFunction_t, var = "LEDFunctions", cmd = "L<A>", rep = "L", ret = "[R|X|T|B|O|F|H|W|C|E|M]+", cnt = 4 },
   ITR = { txt = "Non-significant transitions", tab = otg.IgnoreTrans_t, var = "IgnoreTransitions", cmd = "IT", rep = "T", ret = "[0|1]" },
   REF = { txt = "Reference voltage", tab = otg.RefVoltage_t, var = "ReferenceVoltage", cmd = "VR", rep = "V", ret = "%d" },
   HOT = { txt = "Domestic hot water enable", tab = otg.DHWsetting_t, var = "DHWSetting", rep = "W", ret = "[0|1|A]" }
}

-- Changes for firmware version 4
local otgVersionConfig_t = {
   [4] = { 
           GW   = { rep = "M", ret = "PR: M=([M|G])", map_t = { M = "0", G = "1" } },
           LED  = { ret = "PR: L=([R|X|T|B|O|F|H|W|C|E|M|P]+)", cnt = 6 },
           ITR  = { txt = "Ignore mid-bit transitions", ret = "PR: T=([0|1])" },
           ROF  = { txt = "Remote Override Function flags", tab = { [0] = {txt = "Low byte only"}, [1] = {txt = "Low and high byte"} }, 
                    var = "ROFInBothBytes", cmd = "OH", rep = "T", ret = "PR: T=[0|1]([0|1])" },
           REF  = { ret = "PR: V=(%d)" },
           SETB = { txt = "Setback temperature", var = "SetbackTemperature", cmd = "SB", rep = "S", ret = "PR: S=(%d+.%d+)" },
           HOT  = { ret = "PR: W=([0|1|A])" },
           GPIO = { txt = "GPIO configuration <A>", tab = otg.GPIOFunction_t, var = "GPIOConfiguration", cmd = "G<A>", rep = "G", 
                    ret = "PR: G=([%d]+)", cnt = 2 },
           PWR  = { txt = "Current power level", var = "PowerLevel", rep = "P", ret = "PR: P=([L|M|H])" }
         },
   [5] = { 
           VER = { ret = "PR: A=OpenTherm Gateway (.*)" },
		   GW   = { rep = "M", ret = "PR: M=([M|G])", map_t = { M = "0", G = "1" } },
           LED  = { ret = "PR: L=([R|X|T|B|O|F|H|W|C|E|M|P]+)", cnt = 6 },
           ITR  = { txt = "Ignore mid-bit transitions", ret = "PR: T=([0|1])" },
           ROF  = { txt = "Remote Override Function flags", tab = { [0] = {txt = "Low byte only"}, [1] = {txt = "Low and high byte"} }, 
                    var = "ROFInBothBytes", cmd = "OH", rep = "T", ret = "PR: T=[0|1]([0|1])" },
           REF  = { ret = "PR: V=(%d)" },
           SETB = { txt = "Setback temperature", var = "SetbackTemperature", cmd = "SB", rep = "S", ret = "PR: S=(%d+.%d+)" },
           HOT  = { ret = "PR: W=([0|1|A])" },
           GPIO = { txt = "GPIO configuration <A>", tab = otg.GPIOFunction_t, var = "GPIOConfiguration", cmd = "G<A>", rep = "G", 
                    ret = "PR: G=([%d]+)", cnt = 2 },
           PWR  = { txt = "Current power level", var = "PowerLevel", rep = "P", ret = "PR: P=([L|M|H])" }
         },
   [6] = { 
           VER = { ret = "PR: A=OpenTherm Gateway (.*)" },
           GW   = { rep = "M", ret = "PR: M=([M|G])", map_t = { M = "0", G = "1" } },
           LED  = { ret = "PR: L=([R|X|T|B|O|F|H|W|C|E|M|P]+)", cnt = 6 },
           ITR  = { txt = "Ignore mid-bit transitions", ret = "PR: T=([0|1])" },
           ROF  = { txt = "Remote Override Function flags", tab = { [0] = {txt = "Low byte only"}, [1] = {txt = "Low and high byte"} }, 
                    var = "ROFInBothBytes", cmd = "OH", rep = "T", ret = "PR: T=[0|1]([0|1])" },
           REF  = { ret = "PR: V=(%d)" },
           SETB = { txt = "Setback temperature", var = "SetbackTemperature", cmd = "SB", rep = "S", ret = "PR: S=(%d+.%d+)" },
           HOT  = { ret = "PR: W=([0|1|A])" },
           GPIO = { txt = "GPIO configuration <A>", tab = otg.GPIOFunction_t, var = "GPIOConfiguration", cmd = "G<A>", rep = "G", 
                    ret = "PR: G=([%d]+)", cnt = 2 },
           PWR  = { txt = "Current power level", var = "PowerLevel", rep = "P", ret = "PR: P=([L|M|H])" }
         }
}

---------------------------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------------------------

--- STRING SPLIT ---
function string:otg_split(sep)
   local sep, tab_t = sep or ",", {}
   local pattern = string.format("([^%s]+)", sep)
   self:gsub(pattern, function(c)  if (tonumber(c) ~= nil) then tab_t[tonumber(c)] = c end end)	
   return tab_t
end

-- Get variable value.
-- Use SM_SID and THIS_DEVICE as defaults
local function varGet(name, device, service)
	local value = luup.variable_get(service or otg.GATEWAY_SID, name, tonumber(device or otg.Device))
	return (value or '')
end
-- Update variable when value is different than current.
-- Use SM_SID and THIS_DEVICE as defaults
local function varSet(name, value, device, service)
	local service = service or otg.GATEWAY_SID
	local device = tonumber(device or otg.Device)
	local old = varGet(name, device, service)
	if (tostring(value) ~= old) then 
		luup.variable_set(service, name, value, device)
	end
end
--get device Variables, creating with default value if non-existent
local function defVar(name, default, device, service)
	local service = service or otg.GATEWAY_SID
	local device = tonumber(device or otg.Device)
	local value = luup.variable_get(service, name, device) 
	if (not value) then
		value = default	or ''							-- use default value or blank
		luup.variable_set(service, name, value, device)	-- create missing variable with default value
	end
	return value
end
-- Luup Reload function for UI5,6 and 7
local function luup_reload()
	if (luup.version_major < 6) then 
		luup.call_action("urn:micasaverde-com:serviceId:HomeAutomationGateway1", "Reload", {}, 0)
	else
		luup.reload()
	end
end

---------------
-- Functions --
---------------
-- Set a luup failure message
local function setluupfailure(status,devID)
	if (luup.version_major < 7) then status = status ~= 0 end        -- fix UI5 status type
	luup.set_failure(status,devID)
end

-- Update a system variable only if the value will change
local function updateIfNeeded(sid, var, newVal, id, createOnly)
   if (sid ~= nil and var ~= nil and newVal ~= nil and id ~= nil) then
      local curVal = luup.variable_get(sid, var, id)
      local valUpdate = (curVal == nil) or ((createOnly ~= true) and (curVal ~= tostring(newVal)) or false)
      if (valUpdate == true) then
         luup.variable_set(sid, var, newVal, id)
         return true
      end
   end
   return false
end

-- Find child device (Taken from GE Caddx Panel but comes originally from guessed)
local function findChild(deviceId, label)
   for k, v in pairs(luup.devices) do
      if (v.device_num_parent == deviceId and v.id == label) then
         return k
      end
   end
   return nil
end

-- debug
local function debug(s, level)
   if (otg.LogDebug > 0) then
      local lvl = otg.DebugLevel_t[level] or otg.DebugLevel_t.INFO
      if (bitw.band(otg.LogDebug, lvl) > 0) then
         luup.log("OTG: " .. s)
      end
   end
end

-- otgLogInfo
local function otgLogInfo(text)
   if (otg.LogDebug == otg.DebugLevel_t.FILE) then
      local logfile = otg.LogFilename
      -- empty file if it reaches 250kb
      local outf = io.open(logfile , 'a')
      local filesize = outf:seek("end")
      outf:close()
      if (filesize > 250000) then
         local outf = io.open(logfile , 'w')
         outf:write('')
         outf:close()
      end

      local outf = io.open(logfile, 'a')
      local now = socket.gettime()
      outf:write(string.format("%s%s %s\n", os.date("%F %X", now), string.gsub(string.format("%.3f", now), "([^%.]*)", "", 1), text))
      outf:close()
   end
end

-- otgMessage (global function)
local otgLuupTaskHandle = -1
function otgMessage(text, status)
   if (status == nil) then
      luup.task("", 4, nil, -1)
   else
      debug(text)
      otgLuupTaskHandle = luup.task(text, status, "OT Gateway", otgLuupTaskHandle)
      if (status == 2) then
         luup.call_delay("otgMessage", 30, "", false)
      end
   end
end

-- otgCreateChildren
local function otgCreateChildren(child_t)
   debug("otgCreateChildren")
   local childDevices = luup.chdev.start(otg.Device)
   local embed = (varGet(otgPluginInit_t.EMB.var) == "1")
   local key, val
   for key, val in pairs(child_t) do
      local altid = "msg" .. key
      if (otg.ChildDevice_t[key] == nil) then
         otg.ChildDevice_t[key] = findChild(otg.Device, altid)
      end
      local msg = otgMessage_t[key]
      if (msg == nil) then
         debug("Error! No message " .. key)
      elseif (msg.child ~= nil and otg.UPnPDevice_t[msg.child] ~= nil) then
         local dev_t = otg.UPnPDevice_t[msg.child]
         if (otg.ChildDevice_t[key] ~= nil) then
            local init = ""
            if (otg.ChildDevice_t[key] == true) then
               local value = varGet(msg.var)
               init = dev_t.sid .. "," .. dev_t.var .. "=" .. (value or "")
               otg.ChildDevice_t[key] = 0
            end
            local name = "OTG: " .. string.gsub(msg.txt, "%s%(.+%)", "")
            debug("Child device id " .. altid .. " (" .. name .. "), number " .. otg.ChildDevice_t[key])
            luup.chdev.append(otg.Device, childDevices, altid, name, dev_t.dev, dev_t.imp, "", init, embed)
         end
      end
   end
   luup.chdev.sync(otg.Device, childDevices)
end

-- otgDecodeMessage
local function otgDecodeMessage(val1, msgVal, val2)
   local val = ""
   if (msgVal == "u16") then -- unsigned 16
      val = val1*256 + val2
   elseif (msgVal == "s16") then -- signed 16
      val = val1*256 + val2
      if (bitw.band(val1, 0x80) == 0x80) then
         val = -65536 + val
      end
   elseif (msgVal == "f8.8") then -- floating point
      val = val1 + val2/256
      if (bitw.band(val1, 0x80) == 0x80) then
         val = -256 + val
      end
      val = string.format("%.2f", val) -- high accuracy
   else -- byte only types
      if (msgVal == "flag8") then -- flag 8
         local i
         for i = 7, 0, -1 do
            val = val .. ((bitw.band(val1, 2^i) == 0) and "0" or "1")
         end
      elseif (msgVal == "u8") then -- unsigned 8
         val = string.format("%d", val1)
      elseif (msgVal == "s8") then -- signed 8
         val = val1
         if (bitw.band(val1, 0x80) == 0x80) then
            val = -256 + val
         end
      end
      if (val2 ~= nil) then
         val = val .. " " .. otgDecodeMessage(val2, msgVal)
      end
   end
   return val
end

-- otgWriteCommand: write a command to the OTG
local function otgWriteCommand(cmd, response)
   if (cmd == nil) then
      if (Queue.len(otg.SendQueue) > 0) then
         local pop_t = Queue.pop(otg.SendQueue)
         return otgWriteCommand(pop_t.cmd, pop_t.ret)
      else
         return false
      end
   elseif (Queue.len(otg.ResponseQueue) == 0) then
      local success = luup.io.write(cmd, otg.Device)
      debug("Sent command " .. cmd)
      if (success == false) then
         otgMessage("Cannot send message to the OpenTherm Gateway", 2)
         return false
      end
      if (response ~= nil) and (response == true) then
         updateIfNeeded(otg.GATEWAY_SID, "CommandResponse", "", otg.Device)
         otg.ExpectingResponse = true
      elseif (response == nil) then
         if (otg.MajorVersion >= 4) then
            response = string.gsub(cmd, "%s*=%s*", ": ", 1)
         else
            response = "OK"
         end
         Queue.push(otg.ResponseQueue, response)
      elseif (type(response) == "string") then
         Queue.push(otg.ResponseQueue, response)
      end
   else
      Queue.push(otg.SendQueue, {cmd = cmd, ret = response})
   end
end

--- HANDLERS ---

--function otgConfig_t.VER.handler(cmd, version)
local function otgConfig_t_VER_handler(cmd, version)
   debug("otgHandleVersion cmd = " .. cmd .. ", version = " .. version)
   -- Determine firmware version as this has an effect on commands and reponses
   if (version ~= nil) then
      local major = tonumber(string.match(version, "(%d+)\."))
      -- Update the command table if needed
      if (major ~= nil) then
         otg.MajorVersion = major
         if (otgVersionConfig_t[major] ~= nil) then
            local key, elem, x, y
            for key, elem in pairs(otgVersionConfig_t[major]) do
               if (otgConfig_t[key] == nil) then
                  otgConfig_t[key] = {} -- new command
               end
               for x, y in pairs(elem) do
                  otgConfig_t[key][x] = y
               end
            end
         end
      end
   end
   -- Send report commands to Gateway to receive settings
   for i, elem in ipairs(otg.Startup_t) do
      if (otgConfig_t[elem] ~= nil) then
         otgWriteCommand("PR=" .. otgConfig_t[elem].rep, elem) -- get OTG value
      end
   end
end


-- Check the current House Mode (UI7 only) to make sure Eco measures stay active in Vacation mode (global function)
function otgCheckHouseMode() 
	-- Get curent Remote Override Room Setpoint. When zero, Thermostat runs normal program.
	local curROVR, tstamp  = luup.variable_get(otgWatchVar_t.ROVR.sid, otgWatchVar_t.ROVR.var, otgWatchVar_t.ROVR.dev[otg.Device])
	curROVR = tonumber(curROVR) or -1
	debug("otgCheckHouseMode " .. curROVR)
	if (curROVR == 0) then
		local now = os.time() - 60
		if (tstamp > now) then 
			-- Wait a bit if it was changed less then a minute ago, else thermostat may not respond to restoring it properly.
			luup.call_delay("otgCheckHouseMode", 65, "") 
			debug("otgCheckHouseMode re-run in one minute.")
		else
			-- See if House mode is Vacation
			local house_mode = tonumber((luup.attr_get("Mode",0)))
			debug("otgCheckHouseMode House mode is "..house_mode)
			if (house_mode == 4) then
				local ecoState = varGet(otgPluginInit_t.ECO.var)
				-- Check for default ECO mode being active
				measure = otg.EcoMeasure_t.DECO_TMP
				measureOn = (string.find(ecoState, measure.state, 1, true) ~= nil)
				if (measureOn) then 
					-- Active, so restore Remote Override Room Setpoint
					local temp = tonumber(varGet(otgPluginInit_t[measure.var].var)) or 0 
					otgSetCurrentSetpoint(temp,true)
					debug("otgCheckHouseMode restore to Default Eco temp "..temp)
				end	
			end
		end
	end
end

-- Register with ALTUI if installed (global function)
function otgRegisterWithAltUI()
	-- Register with ALTUI once it is ready
	for k, v in pairs(luup.devices) do
		if (v.device_type == "urn:schemas-upnp-org:device:altui:1") then
			if luup.is_ready(k) then
				debug("Found ALTUI device "..k.." registering devices.")
				local arguments = {}
				arguments["newDeviceType"] = "urn:otgw-tclcode-com:device:HVAC_ZoneThermostat:1"	
				arguments["newScriptFile"] = "J_ALTUI_plugins.js"	
				arguments["newDeviceDrawFunc"] = "ALTUI_PluginDisplays.drawHeater"	
--				arguments["newDeviceDrawFunc"] = "ALTUI_PluginDisplays.drawZoneThermostat"	
				arguments["newStyleFunc"] = ""	
				arguments["newDeviceIconFunc"] = ""	
				arguments["newControlPanelFunc"] = ""	
				arguments["newFavoriteFunc"] = ""	

				-- Main device
				luup.call_action(otg.ALTUI_SID, "RegisterPlugin", arguments, k)
			else
				debug("ALTUI plugin is not yet ready, retry in a bit..")
				luup.call_delay("otgRegisterWithAltUI", 10, "", false)
			end
			break
		end
	end
end

-- Initializes the plugin, handlers etc.
function otgStartup(lul_device)
	otg.Device = lul_device
	local i, key, tab

	debug("Starting ... device #" .. tostring(otg.Device))
   
	-- Initialize UPnP variables
	for key, tab in pairs(otgPluginInit_t) do
		local sid = tab.sid or otg.GATEWAY_SID
		local init = tab.init or ""
		local reset = tab.reset or false
		if luup.short_version then
			-- luup.short_version is new in UI7.30 and up so is good check
			-- 7.30 and up have lable and command as documented in wiki
			if tab.var == "CustomModeConfiguration" then
				tab.init = "CMDNormal;Normal;"..otg.HVAC_USER_SID.."/SetEnergyModeTarget/NewModeTarget=Normal|CMDEco;Eco;"..otg.HVAC_USER_SID.."/SetEnergyModeTarget/NewModeTarget=EnergySavingsMode"
			end
		end
		updateIfNeeded(sid, tab.var, init, otg.Device, not(reset))
	end

	-- For UI7 update the JS reference
	local ui7Check = varGet(otgPluginInit_t.UI7.var)
	if (luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
		varSet(otgPluginInit_t.UI7.var, "true")
		luup.attr_set("device_json", "D_OpenThermGateway_UI7.json", otg.Device)
		luup_reload()
	end
	otg.ui7Check = (ui7Check == "true")

	-- Generate children
	local childList = varGet(otgPluginInit_t.CHD.var)
	otg.MsgCreateChild_t = childList:otg_split()
	otgCreateChildren(otg.MsgCreateChild_t)
	
	-- Register with ALTUI for proper drawing, we use build-in drawZoneThermostat (or drawHeater)
	otgRegisterWithAltUI()

	-- See if user disabled plug-in 
	local isDisabled = luup.attr_get("disabled", otg.Device)
	if ((isDisabled == 1) or (isDisabled == "1")) then
		luup.log("Init: Plug-in version "..otg.PLUGIN_VERSION.." - DISABLED",2)
		otg.Disabled = true
		-- Now we are done. Mark device as disabled
		return true, "Plug-in Disabled.", otg.Description
	end

	-- Get log path
	local path = varGet(otgPluginInit_t.LOG.var)
	if (string.sub(path, string.len(path)) ~= "/") then path = path .. "/" end
	if (path ~= nil) then
		local f = io.open(path, "r")
		if (f ~= nil) then
			otg.LogPath = path
		else
			debug(path .. " does not exist.")
		end
	end
   
	-- Make debug file names device unique
	otg.LogFilename = otg.LogPath .. string.gsub(otg.LogFilename, "<id>", tostring(otg.Device))
	otg.LogDebug = tonumber(varGet(otgPluginInit_t.DBG.var))

	-- Check if connected via IP
	local ip = luup.attr_get("ip",otg.Device)
	if (ip ~= "") then
		local ipaddr, port = string.match(ip, "(.-):(.*)")
		debug("IP = " .. ipaddr .. ", port = " .. port)
		luup.io.open(otg.Device, ipaddr, tonumber(port))
	end
   
	-- Check connection
	if (luup.io.is_connected(otg.Device) == false) then
		otgMessage("Please select the Serial device or IP address for the OpenTherm Gateway", 2)
		setluupfailure(2, otg.Device)
		return false
	end
   
	-- Register luup web handlers
	luup.register_handler("otgCallbackHandler", "GetMessages" .. otg.Device)
	luup.register_handler("otgCallbackHandler", "GetSupportedMessages" .. otg.Device)
	luup.register_handler("otgCallbackHandler", "GetMessageFile" .. otg.Device)
	luup.register_handler("otgCallbackHandler", "GetConfiguration" .. otg.Device)
   
	-- Register variables to watch
	for key, tab in pairs(otgWatchVar_t) do
		if (tab.src ~= "") then
			local devices = varGet(tab.src)
			if (devices ~= "") then
				tab.dev = devices:otg_split()
				for i, val in pairs(tab.dev) do
					-- V1.15 Check device still exists to avoid responding to any device changing the variable
					if luup.devices[i] then
						debug("Registering variable " .. tab.var .. " from device " .. i)
						luup.variable_watch("otgGenericCallback", tab.sid, tab.var, i)
					else
						debug("Device "..i.." no longer exists, no registration for "..tab.var)
					end
				end
			end
		else	 
			-- V1.7 add watches support on own device
			tab.dev = {} 
			tab.dev[otg.Device] = otg.Device
			debug("Registering variable " .. tab.var .. " from device " .. otg.Device)
			luup.variable_watch("otgGenericCallback", tab.sid, tab.var, otg.Device)
		end
	end
   
	-- Get error count locally
	local errors = varGet(otgPluginInit_t.ERR.var)
	string.gsub(errors, "([^,]+)", function(c) otg.ErrorCnt_t[#otg.ErrorCnt_t + 1] = tonumber(c) end)

	-- Get firmware version
	local success = otgWriteCommand("PR=" .. otgConfig_t.VER.rep, "VER") -- get Firmware version
	if (success == false) then
		setluupfailure(1, otg.Device)
		return false
	end

	-- Store gateway mode locally
	otg.GatewayMode = (varGet(otgConfig_t.GW.var) == "1")
   
	-- Set timer to update gateway clock periodically & check connection (make sure the first call is at 0 seconds)
	local when = os.date("%Y-%m-%d %H:%M:00", (os.time() + 60))
	luup.call_timer("otgClockTimer", 4, when, "", "")
   
	-- Fake ventilation support for Humidity sensor
	if (otgWatchVar_t.HUMY.dev ~= nil) then
		otgWriteCommand("SR=70:0,0")
	end
	
	-- Start looking at the House Mode on UI7 so we can lock the temp override when in Vacation Mode
	if (otg.ui7Check) then luup.call_delay("otgCheckHouseMode", 180, "") end
   
	-- Done
	setluupfailure(0, otg.Device)
	return true
end

-- otgIncoming (global function)
function otgIncoming(data)
    if (luup.is_ready(lul_device) == false or otg.Disabled == true) then
        return
    end
	debug("Incoming data = " .. data)
	otg.LastResponse = os.time()
	local comm = updateIfNeeded(otg.HA_DEV_SID, "CommFailure", 0, otg.Device)
	if (comm == true) then
		-- Clear communication error message
		otgMessage()
	end
	if (string.match(data, "[A|B|R|T]%x%x%x%x%x%x%x%x") ~= nil) then
      local sender = otg.MsgInitiator_t[string.sub(data, 1, 1)] or "Unknown"
      local override = (sender == "Answer" or sender == "Response")
      local info = tonumber("0x" .. string.sub(data, 2, 3))
      local parity = bitw.rshift(info, 7)
      local ctype = otg.MsgType_t[bitw.band(bitw.rshift(info, 4), 0x07)]
      local msg = tonumber("0x" .. string.sub(data, 4, 5))
      local msgTxt = "UNKNOWN"
      local msgVal = "flag8"
      local msgVar = ""
      local msgFlags = nil
      -- Keep track of unsupported message IDs
      if ((ctype == "Read-Ack" or ctype == "Write-Ack") and otg.MsgSupported_t[msg] == nil and override == false) then
         otg.MsgSupported_t[msg] = true
      end
      -- Determine if the value received will update the variable
      local valid = false
      if (ctype == "Read-Ack") then
         valid = (override == true and otg.MsgSupported_t[msg] == nil) or (override == false and otg.MsgSupported_t[msg] ~= nil)
      elseif (ctype == "Write-Data") then
         valid = true
      elseif (ctype == "Data-Invalid") then
         valid = override
      end
      if (otgMessage_t[msg] ~= nil) then
         msgTxt = otgMessage_t[msg].txt
         msgVal = otgMessage_t[msg].val or "flag8"
         msgVar = otgMessage_t[msg].var or ""
         msgFlags = otgMessage_t[msg].flags
         if (msgVar == "" and msg > 0) then
            debug("*** No variable for message " .. msg .. " (" .. msgTxt .. ") ***")
         end
      end
      local val1 = tonumber("0x" .. string.sub(data, 6, 7))
      local val2 = tonumber("0x" .. string.sub(data, 8, 9))
      local val = 0
      -- Format value
      if (type(msgVal) == "table") then
         val = otgDecodeMessage(val1, msgVal.hb) .. " " .. otgDecodeMessage(val2, msgVal.lb)
      else
         val = otgDecodeMessage(val1, msgVal, val2)
      end
      local s = string.format("%10s: %-14s %s = ", sender, ctype, msgTxt) .. val
      otgLogInfo(data .. " (" .. s .. ")")
      debug(s, "MSG")
      -- Optional: decode flags
      val1 = val1 * 256 + val2
      if (msgFlags ~= nil) then
         for i, item in pairs(msgFlags) do
            local flagVal = ((bitw.band(val1, i) == 0) and "0" or "1")
            debug(">> " .. item.txt .. ": " .. flagVal, "FLAG")
            if (item.var ~= nil and valid == true) then
               updateIfNeeded(item.sid or otg.GATEWAY_SID, item.var, flagVal, otg.Device)
            end
         end
      end
      -- Update UPnP variable
      if (msgVar ~= "" and valid == true) then
         local sid = otgMessage_t[msg].sid or otg.GATEWAY_SID
         if (msgVal == "f8.8" and sid ~= otg.GATEWAY_SID) then
            val2 = string.format("%.1f", tonumber(val))
            updateIfNeeded(sid, msgVar, val2, otg.Device) -- use lower accuracy for non-gateway variables
			if (msg == 16 or msg == 9) then  --V1.18 On CurrentSetpoint or Remote Override room setpoint, also update SetPointTarget.
				updateIfNeeded(otg.TEMP_SENS_SID, "SetPointTarget", val2, otg.Device) -- use lower accuracy for non-gateway variables
				if (msg == 16) then  --V1.18 On CurrentSetpoint, also update Temp1 CurrentSetpoint.
					updateIfNeeded(otg.TEMP_SENS_SID, "CurrenSetpoint", val2, otg.Device) -- use lower accuracy for non-gateway variables
				end
			end
            sid = otg.GATEWAY_SID -- set high accuray value in gateway variable as well
         end
         if (type(msgVar) == "table") then
            local hb, lb = string.match(val, "([^%s]*) (.*)")
            updateIfNeeded(sid, msgVar.hb, hb, otg.Device)
            updateIfNeeded(sid, msgVar.lb, lb, otg.Device)
         else
            if (otg.MsgCreateChild_t[msg] ~= nil and otgMessage_t[msg].child ~= nil) then
               debug("Value update to be done on child")
               local child = otg.ChildDevice_t[msg]
               if (child ~= nil) then
                  updateIfNeeded(otg.UPnPDevice_t[otgMessage_t[msg].child].sid, otg.UPnPDevice_t[otgMessage_t[msg].child].var, val, child)
               else
                  debug("Child not present: will create one")
                  otg.ChildDevice_t[msg] = true
               end
            end
            updateIfNeeded(sid, msgVar, val, otg.Device)
            if (otg.ChildDevice_t[msg] == true) then
               otgCreateChildren(otg.MsgCreateChild_t)
            end
         end
      end
      -- Optional: Update MCV specific vars
      if (msg == 0 and val1 ~= otg.LastStatus) then
         otg.LastStatus = val1
         local chEnabled = varGet("StatusCHEnabled") -- Thermostat request to heat
         local chMode = varGet("StatusCHMode") -- Boiler acknowledges to heat
         local coolEnabled = varGet("StatusCoolEnabled") -- Thermostat request to cool
         local coolMode = varGet("StatusCooling") -- Boiler acknowledges to cool
         local modeState = "Idle"
         local modeStatus = "Off"
         if (chEnabled == "1" and chMode == "1") then
            modeState = "Heating"
            modeStatus = "HeatOn"
         elseif (chEnabled == "1" and chMode == "0") then
            modeState = "PendingHeat"
         elseif (coolEnabled == "1" and coolMode == "1") then
            modeState = "Cooling"
            modeStatus = "CoolOn"
         elseif (coolEnabled == "1" and coolMode == "0") then
            modeState = "PendingCool"
         end
         updateIfNeeded(otg.HVAC_STATE_SID, "ModeState", modeState, otg.Device)
         updateIfNeeded(otg.HVAC_USER_SID, "ModeStatus", modeStatus, otg.Device)
      end
      return true
   else
	  debug("Incoming data not a message. Length: " .. string.len(data or "").. ". return on zero length data.")
      otgLogInfo(data)
	  if (string.len(data or "") == 0) then
		return true
	  end
   end
   if (otg.ExpectingResponse == true) then
      otg.ExpectingResponse = false
      updateIfNeeded(otg.GATEWAY_SID, "CommandResponse", data, otg.Device)
   elseif (Queue.len(otg.ResponseQueue) > 0) then
      local elem = Queue.pop(otg.ResponseQueue)
      local elem_t = otgConfig_t[elem]
      if (elem_t ~= nil) then -- a known message
         local val = string.match(data, elem_t.ret) -- check expected response
         if (elem_t.map_t ~= nil) then -- apply mapping if available
            for key, ret in pairs(elem_t.map_t) do
               if (string.match(val, key) ~= nil) then
                  val = ret
               end
            end
         end
         if (val ~= nil) then -- valid response
            local valOld = varGet(elem_t.var)
            if (valOld ~= "" and valOld ~= val and elem_t.cmd ~= nil) then
               val = valOld -- current setting takes precedence
               if (elem_t.cnt ~= nil) then
                  local start = string.byte(string.match(elem_t.cmd, "<(.)>"))
                  for i = 1, elem_t.cnt do
                     local cmd = string.gsub(elem_t.cmd, "<(.)>", string.char(start + i - 1))
                     otgWriteCommand(cmd .. "=" .. string.sub(val, i, i))
                  end
               else
                  otgWriteCommand(elem_t.cmd .. "=" .. val)
               end
            end
            if (elem == "GW") then
               otg.GatewayMode = (val == "1")
            end
            updateIfNeeded(otg.GATEWAY_SID, elem_t.var, val, otg.Device)
            if (elem == "VER") then
				otgConfig_t_VER_handler(data, val)
            end
         else
            debug("Error for cmd: " .. elem .. "; expected " .. elem_t.ret .. " but got " .. data)
         end
      elseif (string.match(data, elem) == nil) then
         debug("Error: expected " .. elem .. " but got " .. data)
      end
      otgWriteCommand() -- Write next command if there is one in the queue
   elseif (string.find(data, "Error") ~= nil) then -- Error received
      local errNr = tonumber(string.match(data, "(%d+)"))
      otg.ErrorCnt_t[errNr] = otg.ErrorCnt_t[errNr] + 1
      local errors = otg.ErrorCnt_t[1]
      for i = 2, 4 do
         errors = errors .. "," .. otg.ErrorCnt_t[i]
      end
      varSet("Errors", errors)
   else
      debug("Unknown message")
   end
   return true
end

--- TIMERS --- (global function)
function otgClockTimer(dummy)
   local now = os.time()
   if (otg.LastResponse > 0 and (now - otg.LastResponse > 60)) then
luup.log ("OTGW: Lost connection, no data for 2 mins.")
      -- We have not received anything in the last minute
      local first = updateIfNeeded(otg.HA_DEV_SID, "CommFailure", 1, otg.Device)
      if (first == true) then 
luup.log ("OTGW: Lost connection, is new state.")
         otgMessage("Communication failure: last communication at " .. os.date("%F / %X", otg.LastResponse), 1)
	     -- Check if connected via IP, then try to reconnect. Does not recover.
--	     local ip = luup.attr_get("ip",otg.Device)
--	     if (ip ~= "") then
--luup.log ("OTGW: Lost connection, is over IP.")
--           if (luup.io.is_connected(otg.Device) == false) then
--luup.log ("OTGW: Lost connection, IP connection lost.")
--		       local ipaddr, port = string.match(ip, "(.-):(.*)")
--		       debug("Reconnect IP = " .. ipaddr .. ", port = " .. port)
--		       luup.io.open(otg.Device, ipaddr, tonumber(port))
--	        end
--		    -- Check connection is up again
--	        if (luup.io.is_connected(otg.Device) == false) then
--		       otgMessage("Unable to reconnect", 2)
--luup.log ("OTGW: Lost connection, IP connection cannot be restored.")
--            else	  
--luup.log ("OTGW: Lost connection, IP connection reestablished.")
 --              updateIfNeeded(otg.HA_DEV_SID, "CommFailure", 0, otg.Device)
--            end
--          end
      end
   end
   local sync = varGet(otgPluginInit_t.CLK.var)
   if (sync ~= nil and tonumber(sync) ~= otg.ClockSync_t.NONE) then
      otgSetClock(true)
   end
   luup.call_delay("otgClockTimer", 60, "")
end

--- ACTION FUNCTIONS ---

-- otgSetCurrentSetpoint (global function)
function otgSetCurrentSetpoint(NewCurrentSetpoint)
   debug("otgSetCurrentSetpoint " .. (NewCurrentSetpoint or "")..", constant "..(Constant and "true" or "false"))
   if (otg.GatewayMode == true) then
      -- If negative value, subtract from current
      local setpoint = tonumber(NewCurrentSetpoint)
      if (setpoint ~= nil and setpoint < 0) then
         local current = luup.variable_get(otg.TEMP_SETP_SID, "CurrentSetpoint", otg.Device)
         setpoint = current + setpoint
		 if setpoint < otg.MinimalSetPoint then setpoint = otg.MinimalSetPoint end -- avoid temp set too low
      end
--      updateIfNeeded(otg.TEMP_SETP_SID, "CurrentSetpoint", setpoint, otg.Device)
      updateIfNeeded(otg.TEMP_SETP_SID, "SetpointTarget", setpoint, otg.Device)
      return otgWriteCommand("TT="..setpoint) -- Temperature temporary
   else
      otgMessage("SetCurrentSetpoint only possible in Gateway mode", 2)
   end
end

-- otgSetModeTarget (global function)
function otgSetModeTarget(NewModeTarget)
   debug("otgSetModeTarget " .. (NewModeTarget or ""))
   if (otg.GatewayMode == true) then
      if (NewModeTarget == "Off") then
         return otgWriteCommand("TT=0") -- Schedule
      elseif (NewModeTarget == "HeatOn") then
         local setpoint = luup.variable_get(otg.TEMP_SETP_SID, "CurrentSetpoint", otg.Device)
         return otgWriteCommand("TC=" .. setpoint) -- Temperature constant
      else
         debug("NewModeTarget " .. NewModeTarget ..  " not supported")
      end
   else
      otgMessage("SetModeTarget only possible in Gateway mode", 2)
   end
end

-- otgUpdateEcoState (global function)
function otgUpdateEcoState(item, onOff)
   local ecoState = varGet(otgPluginInit_t.ECO.var)
   if (onOff == "on") then
      ecoState = ecoState .. "[" .. item .. "]"
   else
      ecoState = string.gsub(ecoState, "%[" .. item .. "%]", "")
   end
   local state = (ecoState == "" and "Normal" or "EnergySavingsMode")
   debug("Ecostate = " .. ecoState .. "; state = " .. state)
   updateIfNeeded(otgPluginInit_t.SAV.sid, otgPluginInit_t.SAV.var, state, otg.Device)
   return updateIfNeeded(otg.GATEWAY_SID, otgPluginInit_t.ECO.var, ecoState, otg.Device)
end

local otgOpenTime = 0
-- otgEvalCondition
local function otgEvalCondition(check)
	local result = false
	local delay = 0
	-- For UI7 we do not use the security panel but build in house mode, so val will be empty
	if (otg.ui7Check and check.cond == "AWAY") then
		-- Check for Away or Vacation in UI7
		debug("Starting evaluation of House Mode ")
		local house_mode = tonumber((luup.attr_get("Mode",0)))
		result = (house_mode == 2 or house_mode == 4)
		debug("Evaluation of condition House Mode has result: " .. (result and "true" or "false"))
		return result, 0
	end
	local val = varGet(check.var)
	debug("Starting evaluation of variable " .. check.var)
	if (val ~= "") then
		if (check.cond == "AWAY") then
			-- Check status of panel device
			local panelState = varGet("DetailedArmMode", tonumber(val),otg.PARTITION_SID)
			result = (panelState == "Armed" or panelState == "ArmedInstant")
		elseif (check.cond == "OPEN") then
			local device_t = val:otg_split()
			local i, elem
			for i, elem in pairs (device_t) do
				local deviceState = luup.variable_get(otg.DOOR_SENS_SID, "Tripped", i)
				debug("Device " .. i .. " = " .. deviceState)
				result = result or (deviceState == "1")
			end
			if (result == true and otgOpenTime == 0) then
				otgOpenTime = os.time()
			elseif (result == false) then
				otgOpenTime = 0
			end
		elseif (check.cond == "TEMPOUT") then
			local tempOut = varGet(otgMessage_t[27].var)
			local tempIn = varGet(otgMessage_t[24].var)
			result = (tonumber(tempOut) < tonumber(tempIn))
		elseif (check.cond == "DELAY") then
			local now = os.time()
			delay = val * 60
			result = (now >= otgOpenTime + delay)
			if (result == true) then
				delay = 0 -- no need to re-evaluate
			end
		end
	end
	debug("Evaluation of condition " .. check.cond .. " has result: " .. (result and "true" or "false"))
	return result, delay
end

local delayedMeasure_t
-- otgApplyEcoMeasures (global function)
function otgApplyEcoMeasures(measure_t, forceOff)
	if (type(measure_t) == "string") then
		measure_t = delayedMeasure_t
	end
	local apply = false
	forceOff = forceOff or false -- true when called with delay
	local ecoState = varGet(otgPluginInit_t.ECO.var)
	local measure, val
	for measure, val in pairs(measure_t) do
		local var = otgPluginInit_t[val.var].var
		debug(measure .. " / " .. var)
		local action = varGet(var)
		if (action ~= "" and action ~= "0") then
			local measureOn = (string.find(ecoState, otg.EcoMeasure_t[measure].state, 1, true) ~= nil)
			local delay = 0
			if (forceOff == false) then
				-- Not a forced off, so evaluate what we need to do
				if (val.chk ~= nil) then
					-- Check conditions
					if (val.chk.cond == nil) then
						local key, t
						apply = true
						for key, t in pairs(val.chk) do
							local a, d = otgEvalCondition(t)
							apply = apply and a
							if (d > delay) then delay = d end
						end
					else
						apply, delay = otgEvalCondition(val.chk)
					end
				else -- When no paramter to check, apply change	always (default Eco)
					apply = true
				end
			else -- force eco measure off
				apply = false
			end
			debug("Evaluation done; apply = " .. (apply and "true" or "false") .. ", delay = " .. delay)
			if (apply == false and measureOn == true) then
				debug("Reverting eco measure " .. val.txt)
				if (measure == "DECO_DHW" or measure == "PART_DHW") then
					otgSetDomesticHotWater("Automatic")
				elseif (measure == "DECO_TMP" or measure == "PART_TMP" or measure == "DOOR_TMP") then
					-- Assumption: it cannot be that you were armed away with the doors open
					otgSetModeTarget("Off")
				end
				otgUpdateEcoState(otg.EcoMeasure_t[measure].state, "off")
			elseif (apply == true and measureOn == false) then
				debug("Applying eco measure " .. val.txt)
				if (measure == "DECO_DHW" or measure == "PART_DHW") then
					otgSetDomesticHotWater("Disable")
				elseif (measure == "DECO_TMP" or measure == "PART_TMP" or measure == "DOOR_TMP") then
					otgSetCurrentSetpoint(action)
				else
					debug("Unimplemented measure: " .. measure)
				end
				otgUpdateEcoState(otg.EcoMeasure_t[measure].state, "on")
			elseif (delay > 0 and measureOn == false) then
				debug("Will re-evaluate eco measure " .. val.txt .. " in " .. delay .. " seconds")
				delayedMeasure_t = measure_t
				luup.call_delay("otgApplyEcoMeasures", delay, "delayedMeasure_t")
			end
		end
	end
	return apply
end

-- otgSetEnergyModeTarget (global function)
function otgSetEnergyModeTarget(NewModeTarget)
	debug("otgSetEnergyModeTarget " .. (NewModeTarget or ""))
	if (otg.GatewayMode == true) then
		if (NewModeTarget == "EnergySavingsMode" or NewModeTarget == "Normal") then
			otgApplyEcoMeasures(otg.EcoMeasure_t, (NewModeTarget == "Normal"))
		else
			debug("NewModeTarget " .. NewModeTarget ..  " not supported")
		end
	else
		otgMessage("SetEnergyModeTarget only possible in Gateway mode", 2)
	end
end

-- otgGenericCallback: Generic callback function used to watch variables changing status (global function)
function otgGenericCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	debug("otgGenericCallback device " .. (lul_device or "") .. ", new value = " .. (lul_value_new or ""))
	if (otgWatchVar_t.TEMP.dev ~= nil and otgWatchVar_t.TEMP.dev[lul_device]) then
		otgSetOutsideTemperature(lul_value_new)
	elseif (otgWatchVar_t.HUMY.dev ~= nil and otgWatchVar_t.HUMY.dev[lul_device] ~= nil) then
		otgSetRoomHumidity(lul_value_new)
	elseif (otgWatchVar_t.ROVR.dev ~= nil and otgWatchVar_t.ROVR.dev[lul_device] ~= nil) then  -- V1.7
		otgCheckHouseMode()
	else
		if (otgWatchVar_t.PART.dev ~= nil and otgWatchVar_t.PART.dev[lul_device] ~= nil and lul_variable == otgWatchVar_t.PART.var) then
			otgApplyEcoMeasures({ PART_DHW = otg.EcoMeasure_t.PART_DHW, PART_TMP = otg.EcoMeasure_t.PART_TMP })
		elseif (otgWatchVar_t.DOOR.dev ~= nil and otgWatchVar_t.DOOR.dev[lul_device] ~= nil and lul_variable == otgWatchVar_t.DOOR.var) then
			otgApplyEcoMeasures({ DOOR_TMP = otg.EcoMeasure_t.DOOR_TMP })
		end
	end
end

-- otgSetOutsideTemperature (global function)
function otgSetOutsideTemperature(NewTemperature)
	debug("otgSetOutsideTemperature " .. (NewTemperature or ""))
	if (otg.GatewayMode == true) then
		return otgWriteCommand("OT=" .. NewTemperature) -- Outside temperature
	else
		otgMessage("SetOutsideTemperature only possible in Gateway mode", 2)
		return false
	end
end

-- otgSetRoomHumidity (global function)
function otgSetRoomHumidity(NewLevel)
	debug("otgSetRoomHumidity " .. (NewLevel or ""))
	if (otg.GatewayMode == true) then
		return otgWriteCommand("SR=78:" .. NewLevel .. ",0") -- Room Humidity
	else
		otgMessage("SetRoomHumidity only possible in Gateway mode", 2)
		return false
	end
end

-- otgSendCommand (global function)
function otgSendCommand(Command)
	debug("otgSendCommand " .. (Command or ""))
	return otgWriteCommand(Command, true) -- no checking on input
end

-- otgSetDomesticHotWater (global function)
function otgSetDomesticHotWater(NewMode)
	debug("otgSetDomesticHotWater " .. (NewMode or ""))
	local dmw_t = { Automatic = "A", Disable = "0", Enable = "1" }
	if (dmw_t[NewMode] ~= nil) then
		updateIfNeeded(otg.GATEWAY_SID, otgConfig_t.HOT.var, dmw_t[NewMode], otg.Device)
		return otgWriteCommand("HW=" .. dmw_t[NewMode])
	else
		debug("Mode " .. NewMode .. " not valid")
		return false
	end
end

-- otgSetClock (global function)
function otgSetClock(timer)
   debug("otgSetClock")
   timer = timer or false
   if (otg.GatewayMode == true) then
      local now = os.date("*t")
      local dow = now.wday - 1
      if (dow == 0) then 
         dow = 7 
      end
      otgWriteCommand(string.format("SC=%d:%02d/%d", now.hour, now.min, dow)) -- V1.17
      if (otg.MajorVersion >= 4) then -- SR command only available from FW4
         local sync = tonumber((varGet(otgPluginInit_t.CLK.var))) or 0
         if (timer == false or sync == otg.ClockSync_t.DATE or sync == otg.ClockSync_t.YEAR) then
            otgWriteCommand("SR=21:" .. now.month .. "," .. now.day)
         end
         if (timer == false or sync == otg.ClockSync_t.YEAR) then
            local hb = math.floor(now.year / 0x100)
            local lb = now.year % 0x100
            otgWriteCommand("SR=22:" .. hb .. "," .. lb)
         end
      end
   else
      otgMessage("SetClock only possible in Gateway mode", 2)
   end
end

-- otgResetErrorCount: 0 resets all errors (global function)
function otgResetErrorCount(Index)
   debug("otgResetErrorCount " .. Index)
   local nr = tonumber(Index)
   if (nr >= 0 and nr <= 4) then
      for i = 1, 4 do
         otg.ErrorCnt_t[i] = (nr == 0 or nr == i) and 0 or otg.ErrorCnt_t[i]
      end
      local errors = otg.ErrorCnt_t[1]
      for i = 2, 4 do
         errors = errors .. "," .. otg.ErrorCnt_t[i]
      end
      return luup.variable_set(otg.GATEWAY_SID, "Errors", errors, otg.Device)
   else
      debug("Illegal value to reset error count")
      return false
   end
end

--[[
-- table2Json: converts a lua table to json format
function table2Json(o)
   if (type(o) == 'table') then
      local s = '{ '
      if (next(o) == nil) then
         s = '{}'
      else
         for k, v in pairs(o) do
            s = s .. '"' .. k .. '": ' .. table2Json(v) .. ', '
         end
         s = string.sub(s, 1, -3) .. ' }'
      end
      return s
   else
      return '"' .. string.gsub(tostring(o), "%c", "") .. '"'
   end
end
]]

-- dumpFile: dump a file to stdout
function dumpFile(filename)
   local inf = io.open(filename, 'r')
   if (inf == nil) then
      pmMessage("Cannot open file " .. filename, 2)
      return false
   end
   local when = os.date('%x %X')
   local str = string.format("Status of file %s at %s\n", filename, when) .. "\n" .. inf:read("*all")
   inf:close()
   return str
end

-- otgCallbackHandler(lul_request, lul_parameters, lul_outputformat) (global function)
function otgCallbackHandler(lul_request, lul_parameters, lul_outputformat)
   debug("otgCallbackHandler: request " .. lul_request)
   if (lul_outputformat ~= "xml") then
      if (lul_request == "GetMessages" .. otg.Device) then
--         return table2Json(otgMessage_t)
         return json.encode(otgMessage_t)
      elseif (lul_request == "GetSupportedMessages" .. otg.Device) then
--         return table2Json(otg.MsgSupported_t)
         return json.encode(otg.MsgSupported_t)
      elseif (lul_request == "GetMessageFile" .. otg.Device) then
         return dumpFile(otg.LogFilename)
      elseif (lul_request == "GetConfiguration" .. otg.Device) then
--         return table2Json(otgConfig_t)
		return json.encode(otgConfig_t) 
-- does not work with dkjson encoding         return json.encode(otgConfig_t) 
      elseif (lul_request == "GetLuaLogFile") then
         return dumpFile("/etc/log/cmh/LuaUPnP.log")
      end
   end
end
