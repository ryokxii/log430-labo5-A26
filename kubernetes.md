# Déploiement sur la grappe Kubernetes de l'ÉTS

ÉTS - LOG430 - Architecture logicielle

Ce guide explique comment vous connecter à la grappe Kubernetes du cours et y déployer vos services. Chaque équipe dispose de son propre **espace de noms** (namespace), partagé par ses quatre membres.

---

## 🎯 Ce que vous allez faire

- Configurer `kubectl` avec les accès fournis par l'équipe technique
- Déployer le Store Manager et le service de paiement sur la grappe
- Exposer vos services et y accéder depuis l'extérieur

---

## ⚙️ 1. Prérequis

### Le VPN

La grappe n'est accessible que depuis le réseau de l'ÉTS. **Connectez-vous d'abord au VPN** avec Cisco Secure Client (`accesvpn.etsmtl.ca`), ou soyez sur le réseau du campus.

Si vous voyez cette erreur, c'est le VPN — pas vos certificats :

```
Unable to connect to the server: dial tcp: lookup atreides.logti.etsmtl.ca: no such host
```

### kubectl

Installez [kubectl](https://kubernetes.io/docs/tasks/tools/) en version **1.34 ou plus récente**. La grappe tourne en 1.36 ; un client trop ancien produira des avertissements et pourra ignorer certains champs.

```bash
kubectl version --client
```

### Vos accès

Votre chargé de laboratoire vous remettra une archive contenant :

| Fichier | Contenu |
|---|---|
| `ca.crt` | Le certificat de l'autorité de la grappe |
| `cert.pem` | Votre certificat client |
| `key.pem` | Votre clé privée |
| `nom_utilisateur.txt` | Votre identifiant (ex. `etudiant_07`) |
| `espaces_de_noms.txt` | L'espace de noms de votre équipe |

> ⚠️ Ces fichiers sont **personnels**. Ne les mettez jamais dans votre dépôt Git.

---

## 🔌 2. Configurez kubectl

Depuis le dossier contenant vos fichiers :

```bash
USER=$(tr -d '\r\n' < nom_utilisateur.txt)
NS=$(tr -d '\r\n' < espaces_de_noms.txt)

kubectl config set-cluster log430 \
  --server=https://atreides.logti.etsmtl.ca:16443 \
  --certificate-authority=ca.crt --embed-certs=true

kubectl config set-credentials "$USER" \
  --client-certificate=cert.pem --client-key=key.pem --embed-certs=true

kubectl config set-context "$USER@log430" \
  --cluster=log430 --user="$USER" --namespace="$NS"

kubectl config use-context "$USER@log430"
```

> ⚠️ Le `tr -d '\r\n'` n'est pas décoratif : les fichiers fournis ont des fins de ligne Windows. Sans lui, votre espace de noms contiendra un retour chariot invisible et vous obtiendrez un `Forbidden` incompréhensible.

> 📝 `--embed-certs=true` intègre les certificats dans votre `kubeconfig`. Vous pouvez ensuite déplacer l'archive sans casser la configuration.

Vérifiez :

```bash
kubectl auth whoami
kubectl get all
```

---

## 🚧 3. Ce que vous pouvez et ne pouvez pas faire

Vos droits sont **complets à l'intérieur de votre espace de noms**, et nuls à l'extérieur. Trois conséquences pratiques.

### Pas d'Ingress

Le groupe d'API `networking.k8s.io` vous est refusé. Pour exposer un service, utilisez **NodePort** :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
spec:
  type: NodePort
  selector:
    app: api-gateway
  ports:
    - port: 8080
      targetPort: 8080
      # pas de nodePort : laissez Kubernetes en attribuer un libre
```

**N'imposez pas de `nodePort`.** Les 25 équipes du cours se partagent la même plage (30000-32767) ; un port déjà pris fait échouer la création du Service. En laissant le champ vide, Kubernetes en choisit un de libre.

Lisez ensuite le port attribué :

```bash
kubectl get svc api-gateway
# NAME          TYPE       CLUSTER-IP     PORT(S)          AGE
# api-gateway   NodePort   10.152.x.x     8080:31742/TCP   1m
#                                              ^^^^^ votre port
```

Votre service est alors accessible sur `http://atreides.logti.etsmtl.ca:31742`.

> 📝 Ce port change à chaque recréation du Service. Relisez-le après chaque `kubectl apply` qui recrée le Service, et notez-le dans votre rapport au moment de la capture.

En développement, `port-forward` reste plus pratique :

```bash
kubectl port-forward svc/api-gateway 8080:8080
```

### Pas de Jobs ni de CronJobs

Le groupe `batch` vous est également refusé. Si vous aviez prévu un Job pour initialiser votre base de données, passez plutôt par un `initContainer` ou un ConfigMap monté dans `/docker-entrypoint-initdb.d`.

### ⚠️ Les underscores sont interdits dans les noms

Kubernetes impose la norme RFC 1123 aux noms de ressources : **minuscules, chiffres et tirets uniquement**. Un underscore est rejeté :

```
The Service "payments_api" is invalid: metadata.name: a lowercase RFC 1123 label
must consist of lower case alphanumeric characters or '-'
```

Ça vous concerne directement. Plusieurs noms hérités de Docker Compose sont **invalides en Kubernetes** :

| Docker Compose | Nom Kubernetes valide |
|---|---|
| `payments_api` | `payments-api` |
| `store_manager` | `store-manager` |
| `mysql_payments` | `mysql-payments` |

Le piège : `config/krakend.json` route vers `http://payments_api:5009`. Ce nom fonctionne en Docker Compose, mais **aucun Service Kubernetes ne pourra le porter**. Vous devez donc renommer le Service **et** mettre à jour `krakend.json` en conséquence, sans quoi KrakenD ne joindra jamais le service de paiement.

C'est aussi vrai pour les noms d'images de conteneurs, qui doivent être entièrement en minuscules.

### La classe de stockage

Pour vos volumes persistants, **omettez `storageClassName`** et laissez la classe par défaut s'appliquer. Elle se nomme `default-storage` sur cette grappe — ne recopiez pas le `local-path` des tutoriels k3s ni le `microk8s-hostpath` d'autres documentations, votre PVC resterait bloqué en `Pending`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

### Commandes qui échoueront

Ce sont des opérations au niveau de la grappe, réservées à l'administration :

```bash
kubectl get namespaces   # Forbidden
kubectl get nodes        # Forbidden
kubectl get pods -A      # Forbidden
```

Ce n'est pas une erreur de configuration.

---

## 📦 4. Publiez vos images

La grappe ne peut pas lire les images de votre machine : elle doit les **télécharger depuis un registre**. Publiez-les sur GHCR, comme au Labo 00.

```yaml
containers:
  - name: store-manager
    image: ghcr.io/<votre-username>/<votre-depot>:latest
    imagePullPolicy: Always
```

> ⚠️ **Si votre paquet GHCR est privé**, la grappe ne pourra pas le télécharger et vos pods resteront en `ImagePullBackOff`. Deux solutions : rendre le paquet public (Package settings → Change visibility), ou créer un secret d'authentification :
>
> ```bash
> kubectl create secret docker-registry ghcr-secret \
>   --docker-server=ghcr.io \
>   --docker-username=<username> \
>   --docker-password=<token-avec-read:packages>
> ```
>
> puis l'ajouter à votre pod :
>
> ```yaml
> spec:
>   imagePullSecrets:
>     - name: ghcr-secret
> ```

---

## 🚀 5. Déployez

### Créez d'abord les ConfigMaps

Le manifeste `k8s-manifests.yml` **référence deux ConfigMaps qu'il ne contient pas**. Créez-les avant tout `apply`, sinon vos pods resteront bloqués en `CreateContainerConfigError` :

```bash
# Configuration de KrakenD
kubectl create configmap krakend-config --from-file=krakend.json=./config/krakend.json \
  --dry-run=client -o yaml | kubectl apply -f -

# Script d'initialisation de la base de donnees
kubectl create configmap db-init --from-file=./db-init/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

Le `--dry-run=client | kubectl apply` rend la commande rejouable : elle crée la ConfigMap la première fois, et la met à jour ensuite. Un simple `kubectl create` échouerait au second passage.

Refaites-les à chaque modification de `krakend.json` ou de `db-init/`, puis redémarrez les déploiements concernés — une ConfigMap modifiée n'est pas rechargée automatiquement.

### Puis appliquez

```bash
kubectl apply -f k8s-manifests.yml

# Suivre le deploiement
kubectl rollout status deployment/store-manager

# Verifier
kubectl get all
```

Pour forcer le rechargement d'une image republiée sous la même étiquette :

```bash
kubectl rollout restart deployment/store-manager
```

---

## 🔍 6. Déboguer

```bash
kubectl get pods                        # etat general
kubectl describe pod <nom>              # evenements : pourquoi un pod ne demarre pas
kubectl logs <nom>                      # logs applicatifs
kubectl logs <nom> --previous           # logs du conteneur precedent, apres un crash
kubectl exec -it <nom> -- bash          # terminal dans le conteneur
kubectl get events --sort-by=.lastTimestamp
```

| Symptôme | Cause habituelle |
|---|---|
| `ImagePullBackOff` | Image privée ou nom d'image erroné |
| `CrashLoopBackOff` | L'application plante au démarrage — voir `logs --previous` |
| `Pending` | PVC non satisfait, ou ressources insuffisantes sur la grappe |
| `CreateContainerConfigError` | ConfigMap ou Secret référencé mais absent |

---

## ⚠️ 7. Vous partagez tout avec votre équipe

Les quatre membres ont **exactement les mêmes droits** dans l'espace de noms. Chacun peut déployer, modifier et **supprimer** ce que les autres ont fait — sans confirmation ni corbeille.

Ce n'est pas un défaut : c'est ce qui vous permet de travailler ensemble. Mais coordonnez-vous avant de lancer un `kubectl delete`.

La grappe est également partagée par les 25 équipes du cours, sur un seul serveur. **N'y exécutez pas de tests de charge** : gardez Locust en local, comme au Labo 04.
