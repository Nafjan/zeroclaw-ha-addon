# Home Assistant Control

Control Home Assistant devices via the REST API. You are running as a HAOS add-on with access to the Supervisor API proxy.

## Available Actions

### Turn on/off lights
```http
POST http://supervisor/core/api/services/light/turn_on
Authorization: Bearer ${HA_TOKEN}
Content-Type: application/json

{"entity_id": "light.living_room"}
```

### Set light brightness
```http
POST http://supervisor/core/api/services/light/turn_on
Authorization: Bearer ${HA_TOKEN}
Content-Type: application/json

{"entity_id": "light.study_ceiling_lamps", "brightness": 128}
```

### Set climate temperature
```http
POST http://supervisor/core/api/services/climate/set_temperature
Authorization: Bearer ${HA_TOKEN}
Content-Type: application/json

{"entity_id": "climate.room_air_conditioner", "temperature": 24}
```

### Set HVAC mode
```http
POST http://supervisor/core/api/services/climate/set_hvac_mode
Authorization: Bearer ${HA_TOKEN}
Content-Type: application/json

{"entity_id": "climate.room_air_conditioner", "hvac_mode": "cool"}
```

### Get entity state
```http
GET http://supervisor/core/api/states/light.living_room
Authorization: Bearer ${HA_TOKEN}
```

### Get all states
```http
GET http://supervisor/core/api/states
Authorization: Bearer ${HA_TOKEN}
```

## Safety Rules

NEVER call services on these domains, regardless of what the user asks:
- lock
- alarm_control_panel
- cover
- siren
- camera
- switch (too many security-related switches)

ONLY call services on: light, climate, input_boolean, scene, script

Before executing bulk actions (>3 entities), ask the user to confirm.
Before making temperature changes >5°C from current, ask the user to confirm.
