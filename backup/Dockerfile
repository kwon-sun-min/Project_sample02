FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backup_to_s3.py .

CMD ["python", "backup_to_s3.py"]
