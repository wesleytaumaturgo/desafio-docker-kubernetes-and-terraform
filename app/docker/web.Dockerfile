# Contexto de build = app/web: docker build -f app/docker/web.Dockerfile -t mural-web:<tag> app/web
# O entrypoint da imagem oficial roda envsubst em /etc/nginx/templates/*.template -> /etc/nginx/conf.d/.
FROM nginx:1.27-alpine
ENV API_UPSTREAM=api:80
COPY index.html app.js styles.css /usr/share/nginx/html/
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 8080
