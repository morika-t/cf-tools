#!/bin/bash

# Show list of Applications running on Cloud Foundry

# Stanislav German-Evtushenko, 2016
# Rakuten inc.

# Dependencies: cf, jq >= 1.5

# Try 'cf curl /v2/apps' to see what input data looks like

set -euo pipefail

# Cache json data for X minutes
# Set as "" to disable caching
CACHE_FOR_X_MIN="10"

PROPERTIES_TO_SHOW_H='# Name State Memory Instances Disk_quota Stack Organization Space Created Updated App_URL Routes_URL Buildpack Detected_Buildpack'
PROPERTIES_TO_SHOW='.entity.name, .entity.state, .entity.memory, .entity.instances, .entity.disk_quota, .extra.stack, .extra.organization, .extra.space, .metadata.created_at, .metadata.updated_at, .metadata.url, .entity.routes_url, .entity.buildpack, .entity.detected_buildpack'

show_usage () {
    cat << EOF
Usage: $(basename "$0") [OPTION]...

  -s <sort options>         pass sort options to 'sort'
  -f <field1,field2,...>    pass field numbers to 'cut -f'
  -c <minutes>              filter objects created within <minutes>
  -u <minutes>              filter objects updated within <minutes>
  -h                        display this help and exit
EOF
}

# Process command line options
opt_sort_options=""
opt_created_minutes=""
opt_updated_minutes=""
opt_cut_fields=""
while getopts "s:c:u:f:h" opt; do
    case $opt in
        s)  opt_sort_options=$OPTARG
            ;;
        c)  opt_created_minutes=$OPTARG
            ;;
        u)  opt_updated_minutes=$OPTARG
            ;;
        f)  opt_cut_fields=$OPTARG
            ;;
        h)
            show_usage
            exit 0
            ;;
        ?)
            show_usage >&2
            exit 1
            ;;
    esac
done

# Default sorting options (See 'man sort')
SORT_OPTIONS=${opt_sort_options:--k1}

# Define command to cut specific fields
if [[ -z $opt_cut_fields ]]; then
    CUT_FIELDS="cat"
else
    CUT_FIELDS="cut -f $opt_cut_fields"
fi

# Post filter
POST_FILTER=""
if [[ -n $opt_created_minutes ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.created_at | (now - fromdate) / 60) as \$created_min_ago |
                 select (\$created_min_ago < $opt_created_minutes) |"
fi
if [[ -n $opt_updated_minutes ]]; then
    POST_FILTER="$POST_FILTER . |
                 (.metadata.updated_at as \$updated_at | if \$updated_at != null then \$updated_at | (now - fromdate) / 60 else null end ) as \$updated_min_ago |
                 select (\$updated_min_ago != null) | select (\$updated_min_ago < $opt_updated_minutes) |"
fi

# The following variables are used to generate cache file path
script_name=$(basename "$0")
user_id=$(id -u)
cf_api=$(cf api)

get_json () {
    next_url="$1"

    next_url_hash=$(echo "$next_url" "$cf_api" | $(which md5sum || which md5))
    cache_filename="/tmp/.$script_name.$user_id.$next_url_hash"

    if [[ -n $CACHE_FOR_X_MIN ]]; then
        # Remove expired cache file
        find "$cache_filename" -maxdepth 0 -mmin +$CACHE_FOR_X_MIN -exec rm '{}' \; 2>/dev/null

        # Read from cache if exists
        if [[ -f "$cache_filename" ]]; then
            cat "$cache_filename"
            return
        fi
    fi

    json_output=""
    while [[ $next_url != null ]]; do
        # Get data
        json_data=$(cf curl "$next_url")
    
        # Generate output
        output=$(echo "$json_data" | jq '[ .resources[] | {key: .metadata.guid, value: .} ] | from_entries')
    
        # Add output to json_output
        json_output=$(echo "${json_output}"$'\n'"$output" | jq -s "add")
    
        # Get URL for next page of results
        next_url=$(echo "$json_data" | jq .next_url -r)
    done
    echo "$json_output"

    # Update cache file
    if [[ -n $CACHE_FOR_X_MIN ]]; then
        echo "$json_output" > "$cache_filename"
    fi
}

# Get organizations
next_url="/v2/organizations?results-per-page=100"
json_organizations=$(get_json "$next_url" | jq "{organizations:.}")

# Get spaces
next_url="/v2/spaces?results-per-page=100"
json_spaces=$(get_json "$next_url" | jq "{spaces:.}")

# Get stacks
next_url="/v2/stacks?results-per-page=100"
json_stacks=$(get_json "$next_url" | jq "{stacks:.}")

# Get applications
next_url="/v2/apps?results-per-page=100"
json_apps=$(get_json "$next_url" | jq "{apps:.}")

# Add extra data to json_spaces
json_spaces=$(echo "$json_organizations"$'\n'"$json_spaces" | \
     jq -s '. | add' | \
     jq '.organizations as $organizations |
         .spaces[] |= (.extra.organization = $organizations[.entity.organization_guid].entity.name) |
         .spaces | {spaces:.}')

# Add extra data to json_apps
json_apps=$(echo "$json_stacks"$'\n'"$json_spaces"$'\n'"$json_apps" | \
     jq -s '. | add' | \
     jq '.stacks as $stacks |
         .spaces as $spaces |
         .apps[] |= (.extra.stack = $stacks[.entity.stack_guid].entity.name |
                     .extra.organization = $spaces[.entity.space_guid].extra.organization |
                     .extra.space = $spaces[.entity.space_guid].entity.name ) |
         .apps | {apps:.}')

# Generate application list (tab-delimited)
app_list=$(echo "$json_apps" |\
    jq -r ".apps[] |
        $POST_FILTER
        [ $PROPERTIES_TO_SHOW | select (. == null) = \"<null>\" | select (. == \"\") = \"<empty>\" ] |
        @tsv")

# Print headers and app_list
(echo $PROPERTIES_TO_SHOW_H | tr ' ' '\t'; echo "$app_list" | sort -t $'\t' $SORT_OPTIONS | nl -w4) | \
    # Cut fields
    eval $CUT_FIELDS | \
    # Format columns for nice output
    column -ts $'\t' | less --quit-if-one-screen --no-init --chop-long-lines
