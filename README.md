#Monitoring_cf_app
##How to use
`ruby cf_app.rb -u my-username -p my-password -o my-orgnization -s my-space -a my-app1,my-app2,...`
##Configure config.yml
###Define host
`host: localhost`
###Define Port
`port: 5000`
###Display Warnings
`send_warnings: true`
###Use JSON format
`format: :JSON`
###Use Nagios format
`format: :NAGIOS`
###Define TCP output
```
output_channels:
  - :TCP
```
###Define STDOUT output
```
output_channels:
  - :STDOUT
```
###Define TCP and STDOUT output
```
output_channels:
  - :STDOUT
  - :TCP
```
###Activate SSL-Verification
`skip_ssl_verification: true`
###Define thresholds
Define the values:
- CPU in percent
- Memory in MB
- Disk in MB
```
thresholds:
  cpu:
    warning: 50
    critical: 80
  memory:
    warning: 300
    critical: 500
  disk:
    warning: 500
    critical: 1000
```
