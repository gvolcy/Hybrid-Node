getBalanceKoios() {
  # HYBRIDNODE_KOIOS_BALANCE_PATCH
  # Upstream getBalanceKoios requests Koios address_utxos as text/csv with
  # select=address,tx_hash,tx_index,value,asset_list and parses it positionally
  # with `IFS=',' read -r _address _tx_hash _tx_index _value _asset_list`.
  # The public Koios API now returns CSV columns in schema order
  # (address,asset_list,tx_hash,tx_index,value), so asset_list - a JSON blob
  # full of commas - lands in column 2. The positional read then shreds the row
  # and `$(( ... + _value ))` aborts with an arithmetic error, crashing
  # CNTools "Show wallet" for any wallet holding native tokens.
  #
  # Fix: request application/json and parse with jq (order-independent, comma
  # safe). asset_list is base64-encoded by the outer jq so it survives the @tsv.
  declare -gA utxos=(); declare -gA utxos_cnt=(); declare -gA assets=(); declare -gA tx_in_arr=(); declare -gA asset_name_maxlen_arr=(); declare -gA asset_amount_maxlen_arr=()

  if [[ -n ${KOIOS_API} && -n ${addr_list+x} ]]; then
    printf -v addr_list_joined '\"%s\",' "${addr_list[@]}"
    [[ $1 != false ]] && extended=true || extended=false
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: application/json")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_addresses\":[${addr_list_joined%,}],\"_extended\":${extended}}' ${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list"
    ! address_utxo_list=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_addresses":['${addr_list_joined%,}'],"_extended":'${extended}'}' "${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${address_utxo_list}\n" && return 1 # print error and return
    [[ -z ${address_utxo_list} || ${address_utxo_list} = '[]' ]] && return
    while IFS=$'\t' read -r _address _tx_hash _tx_index _value _asset_list_b64; do
      [[ -z ${_address} ]] && continue
      index_prefix="${_address},"
      assets["${index_prefix}lovelace"]=$(( ${assets["${index_prefix}lovelace"]:-0} + _value ))
      utxos["${index_prefix}${_tx_hash}#${_tx_index}. ADA"]=${_value}
      utxos_cnt["${_address}"]=$(( ${utxos_cnt["${_address}"]:-0} + 1 ))
      tx_in_arr["${_address}"]="${tx_in_arr["${_address}"]} --tx-in ${_tx_hash}#${_tx_index}"
      if [[ $1 != false ]]; then
        _asset_list=$(base64 -d <<< "${_asset_list_b64}" 2>/dev/null)
        [[ -z ${_asset_list} || ${_asset_list} = 'null' ]] && continue
        while IFS=$'\t' read -r _policy_id _asset_name _quantity; do
          [[ -z ${_policy_id} ]] && continue
          tname="$(hexToAscii ${_asset_name})"
          tname="${tname//[![:print:]]/}"
          [[ ${#tname} -gt ${asset_name_maxlen_arr["${_address}"]:-5} ]] && asset_name_maxlen_arr["${_address}"]=${#tname}
          asset_amount_fmt="$(formatAsset ${_quantity})"
          [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen_arr["${_address}"]:-12} ]] && asset_amount_maxlen_arr["${_address}"]=${#asset_amount_fmt}
          assets["${index_prefix}${_policy_id}.${_asset_name}"]=$(( ${assets["${index_prefix}${_policy_id}.${_asset_name}"]:-0} + _quantity ))
          utxos["${index_prefix}${_tx_hash}#${_tx_index}.${_policy_id}.${_asset_name}"]=${_quantity}
        done < <( jq -cr '.[]? | [.policy_id, .asset_name, .quantity] | @tsv' <<< "${_asset_list}" )
      fi
    done < <( jq -r '.[] | [.address, .tx_hash, .tx_index, .value, ((.asset_list // []) | @json | @base64)] | @tsv' <<< "${address_utxo_list}" )
  fi
}
