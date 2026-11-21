# Icône de l'app : AppIcon.png, faite à partir de KonaPhoto.png (voiture sur le fond de l'app), déjà dans le dépôt. Rien à générer.
import os, sys
sys.exit(0 if os.path.exists("AppIcon.png") else "AppIcon.png manquant")
