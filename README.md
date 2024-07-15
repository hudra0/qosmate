# qosmate

Before installing qosmate, make sure to:

- **Disable any existing QoS services** such as SQM or Qosify on your router to avoid conflicts with the new script.
- Upon first start, it's best to **reboot your router** to clear out all old settings for a clean start.
- **Install qosmate** following the provided instructions, then adjust settings to suit your network needs:

1. Log into your OpenWrt router and download the scripts to your router with this command:

```
wget -O /etc/init.d/qosmate https://raw.githubusercontent.com/hudra0/qosmate/main/etc/init.d/qosmate && chmod +x /etc/init.d/qosmate && wget -O /etc/qosmate.sh https://raw.githubusercontent.com/hudra0/qosmate/main/etc/qosmate.sh && chmod +x /etc/qosmate.sh
```   
