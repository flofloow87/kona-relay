# Icône de l'app : AppIcon.png (création de Flo), déjà dans le dépôt. Rien à générer.
import os, sys
sys.exit(0 if os.path.exists("AppIcon.png") else "AppIcon.png manquant")
