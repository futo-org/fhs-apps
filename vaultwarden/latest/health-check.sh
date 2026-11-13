# Healthy once the server answers /alive, which also opens a database connection.
curl -fsS --max-time 4 http://127.0.0.1:8222/alive > /dev/null
