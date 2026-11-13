# Healthy once the login page renders: the web server only listens after init
# (migrations, search index), and the page queries the users table.
curl -fsS --max-time 4 http://127.0.0.1:8000/accounts/login/ > /dev/null
