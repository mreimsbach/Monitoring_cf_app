#Monitoring_cf_app
##How to use
`ruby cf_app.rb -u my-username -p my-password -o my-orgnization -s my-space -a my-app1,my-app2,...`
##Configure config.yml
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
Define the values in percent:
```
thresholds:
  cpu:
    min: 10
    max: 1
  memory:
    min: 200
    max: 2
  disk:
    min: 100
    max: 3
```
