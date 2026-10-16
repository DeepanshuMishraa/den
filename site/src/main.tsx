import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@fontsource-variable/geist-mono'
import './index.css'
import App from './App.tsx'

const root = document.getElementById('root')
if (!root) throw new Error('index.html is missing <div id="root">, so the site has nowhere to mount.')

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
