FROM python:3.11-slim

WORKDIR /app

COPY create_database.py .

RUN pip install requests mysql-connector-python faker bcrypt cryptography


CMD ["python3", "create_database.py", "create_all"]
