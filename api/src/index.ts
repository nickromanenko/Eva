import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => {
  return c.text('Eva API')
})

app.get('/health', (c) => {
  return c.json({ status: 'ok' })
})

export default {
  // Cloud Run injects PORT (8080); default to 3000 for local dev
  port: Number(process.env.PORT ?? 3000),
  fetch: app.fetch,
}
