FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir flask qrcode[pil] PyJWT gunicorn

COPY app/app.py /app/app.py
COPY app/tpl.html /app/tpl.html
COPY app/page_login.html /app/page_login.html
COPY app/page_panel.html /app/page_panel.html
COPY app/page_reunion.html /app/page_reunion.html
COPY app/page_qr_view.html /app/page_qr_view.html

RUN mkdir -p /app/instance

ENV ADMIN_ENV_FILE=/app/instance/admin.env
ENV JITSI_ENV_FILE=/opt/jitsi-meet/.env
ENV DB_PATH=/app/instance/reuniones.db
ENV LOG_FILE=/app/instance/app.log

EXPOSE 8081

CMD ["gunicorn", "-w", "1", "--threads", "4", "-b", "0.0.0.0:8081", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
