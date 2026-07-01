FROM python:3.12-slim

WORKDIR /app

COPY app/requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt && \
    useradd --system appuser

COPY . .

USER appuser

EXPOSE 8080

CMD ["python", "app/app.py"]