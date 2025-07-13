#!/bin/bash

printf "1. Add Port Forwarding Rules\n"
printf "2. Show Existing Rules\n"
echo -n "What would you like to do? : "
read answ

CHAIN_NAME="CUSTOM-FORWARDING"

case $answ in

	# CASE 1 = ADD NEW RULES
	"1")
		# Get Interface List
		interfaces=($(ls /sys/class/net))

		for i in "${!interfaces[@]}"; do
			echo "$((i+1)). ${interfaces[$i]}"
		done

		echo -n "Input Main Interface: "
		read input_iface

		if [[ $input_iface -ge 1 && $input_iface -le ${#interfaces[@]} ]]; then
			selected_interface="${interfaces[$((input_iface-1))]}"
		else
			echo "Invalid Interface."
		fi

		echo -n "Input Source Port: "
		read input_sport

		echo -n "Input Destination IP: "
		read input_dip

		echo -n "Input Destination Port: "
		read input_dport

		printf "=============\n"
		printf "Interface        : %s\n" $selected_interface
		printf "Source Port      : %s\n" $input_sport
		printf "Destination IP   : %s\n" $input_dip
		printf "Destination Port : %s\n" $input_dport
		printf "\n"


		# Adding IPTABLES Rules
		echo -n "Proceed?(y/n): "
		read answ

		if [[ "$answ" == "y" || "$answ" == "Y" ]]; then

			# Add new custom chain if didn't exist
			if ! iptables -L $CHAIN_NAME -n &>/dev/null; then
					iptables -N $CHAIN_NAME
				iptables -A FORWARD -j $CHAIN_NAME
			fi

			if ! iptables -t nat -L $CHAIN_NAME -n &>/dev/null; then
				iptables -t nat -N $CHAIN_NAME
				iptables -t nat -A PREROUTING -j $CHAIN_NAME
			fi

			# Append New Port Forward Rules
			echo "Adding rules"
			iptables -t nat -A $CHAIN_NAME -i $selected_interface -p tcp --dport $input_sport -j DNAT --to-destination $input_dip:$input_dport
			iptables -A $CHAIN_NAME -p tcp -d $input_dip --dport $input_dport -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
		fi
		;;

	# CASE 2 = SHOW EXISTING RULES
	"2")
		while true; do
			printf "========================\n"
			printf "= FORWARD RULES        =\n"
			printf "========================\n"

			iptables -L $CHAIN_NAME --line-numbers

			printf "\n"

			printf "========================\n"
			printf "= NAT PREROUTING RULES =\n"
			printf "========================\n"

			iptables -t nat -L $CHAIN_NAME --line-numbers

			echo -n "Want to Delete? (y/n): "
			read answ

			if [[ "$answ" == "y" || "$answ" == "Y" ]]; then
				echo -n "FORWARD RULES to DELETE (empty for nothing): "
				read del_forward

				echo -n "NAT PREROUTING to DELETE (empty for nothing): "
				read del_prerouting

				if [[ $del_forward -ne 0 && $del_forward -ne "" ]]; then
					iptables -D $CHAIN_NAME $del_forward
				fi

				if [[ $del_prerouting -ne 0 && $del_prerouting -ne "" ]]; then
					iptables -t nat -D $CHAIN_NAME $del_prerouting
				fi


			else
				break
			fi
		done
		;;
	esac
