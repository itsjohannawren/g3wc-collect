#!/usr/bin/env bash

DEVICE="charger.4825l.walter.fm"
ES_HOST="saga.4825l.walter.fm:9200"
ES_INDEX="stats-energy-%Y.%m.%d"
ES_INDEX_UTC="1"

# ==============================================================================

LAST="0"
CONNECTED="0"
CHARGING="0"

writeES() {
	local UTC

	UTC=()
	if [ "${ES_INDEX_UTC}" = "1" ]; then
		UTC=("-u")
	fi

	curl \
		-s \
		-X POST \
		-H "Content-type: application/json" \
		-d "@/dev/stdin" \
		"http://${ES_HOST}/$(date "${UTC[@]}" +"${ES_INDEX}")/_doc/?refresh=true" \
		>/dev/null \
		<<<"${1}"
}

while true; do
	NOW="$(date +"%s")"
	if [ "${NOW}" = "${LAST}" ]; then
		sleep 0.1
		continue
	fi

	LAST="${NOW}"
	echo "Sampling..."

	VITALS_RAW="$(curl -s http://${DEVICE}/api/1/vitals 2>&1)"
	if [ "$?" != "0" ]; then
		echo "   ERROR: Failed to get vitals from charger"
		sed -e 's/^/   ERROR: /' <<<"${VITALS_RAW}"
		continue
	fi

	VITALS_JSON="$(jq \
		--arg timestamp "${NOW}000" \
		--arg account_id "0" \
		--arg type "ev_charger" \
		--arg subtype "metric" \
		--arg make "Tesla" \
		--arg model "Gen 3 Wall Connector" \
		--arg device "${DEVICE}" \
		'{"@timestamp": $timestamp|tonumber, "account_id": $account_id|tonumber, "type": $type, "subtype": $subtype, "make": $make, "model": $model, "device": $device, "connected": .vehicle_connected, "charging": .contactor_closed, "charging_seconds": .session_s, "charging_watts": (.vehicle_current_a * .grid_v), "charging_watthours": (if .session_s == 0 then 0 else .session_energy_wh end), "input_volts": .grid_v, "input_frequency": .grid_hz, "board_celsius": .pcba_temp_c, "handle_celsius": .handle_temp_c, "controller_celsius": .mcu_temp_c, "uptime_seconds": .uptime_s, "config_state": .config_status, "evse_state": .evse_state} | walk(if type == "boolean" then if . == true then 1 else 0 end else . end)' \
		<<<"${VITALS_RAW}" \
	)"

	echo "   Writing vitals to ES"
	writeES "${VITALS_JSON}"

	NEW_CONNECTED="$(jq -r '.connected' <<<"${VITALS_JSON}")"
	if [ "${NEW_CONNECTED}" != "${CONNECTED}" ]; then
		CONNECTED="${NEW_CONNECTED}"
		echo "   Writing connection event to ES"
		writeES "$(jq -n \
			--arg timestamp "${NOW}000" \
			--arg account_id "0" \
			--arg type "ev_charger" \
			--arg subtype "event" \
			--arg make "Tesla" \
			--arg model "Gen 3 Wall Connector" \
			--arg device "${DEVICE}" \
			--arg connected "${CONNECTED}" \
			--arg event "Handle $(if [ "${CONNECTED}" = "0" ]; then echo "disconnected"; else echo "connected"; fi)" \
			'{"@timestamp": $timestamp|tonumber, "account_id": $account_id|tonumber, "type": $type, "subtype": $subtype, "make": $make, "model": $model, "device": $device, "connected": $connected|tonumber, "event": $event} | walk(if type == "boolean" then if . == true then 1 else 0 end else . end)' \
		)"
	fi

	NEW_CHARGING="$(jq -r '.charging' <<<"${VITALS_JSON}")"
	if [ "${NEW_CHARGING}" != "${CHARGING}" ]; then
		CHARGING="${NEW_CHARGING}"
		echo "   Writing charging event to ES"
		writeES "$(jq -n \
			--arg timestamp "${NOW}000" \
			--arg account_id "0" \
			--arg type "ev_charger" \
			--arg subtype "event" \
			--arg make "Tesla" \
			--arg model "Gen 3 Wall Connector" \
			--arg device "${DEVICE}" \
			--arg charging "${CHARGING}" \
			--arg event "Charging $(if [ "${CHARGING}" = "0" ]; then echo "ended"; else echo "started"; fi)" \
			'{"@timestamp": $timestamp|tonumber, "account_id": $account_id|tonumber, "type": $type, "subtype": $subtype, "make": $make, "model": $model, "device": $device, "charging": $charging|tonumber, "event": $event} | walk(if type == "boolean" then if . == true then 1 else 0 end else . end)' \
		)"
	fi
done
