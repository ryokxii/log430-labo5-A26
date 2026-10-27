# CI/CD du laboratoire 5

Ce document explique comment lancer les pipelines GitHub Actions de Store Manager et de Payment API, publier leurs images Docker sur GHCR et déployer les applications sur la grappe MicroK8s du cours.

## 1. Fonctionnement du pipeline

Chaque dépôt possède son workflow dans `.github/workflows/ci-cd.yml`. Il se déclenche à chaque push sur `main` ou manuellement depuis l'onglet **Actions**, en sélectionnant `main`.

| Job | Machine | Étapes |
|---|---|---|
| Build tests et publication GHCR | Runner Ubuntu fourni par GitHub | Vérification JSON, construction Docker, compilation Python, démarrage d'une pile de test isolée, pytest, vérification commande/paiement, puis publication GHCR. |
| Deploiement ETS et verification fonctionnelle | Runner Windows sur le PC connecté au VPN | Application des ConfigMaps et du manifeste, déploiement de l'image du commit, attente des rollouts et vérification fonctionnelle sur la grappe. |

Le job de déploiement dépend de la réussite du job CI. Un échec des tests empêche la publication et le déploiement. Une publication réussie est suivie d'un déploiement qui peut encore échouer si la grappe est inaccessible ou si le test fonctionnel échoue.

L'image est publiée avec deux tags : `latest` et le SHA complet du commit. Le déploiement utilise le **tag SHA** pour identifier précisément la version installée. Le script remplace `latest` dans une copie temporaire du manifeste avant de l'appliquer.

La pile CI contient les deux API, les deux MySQL, Redis et KrakenD. Chaque dépôt teste sa propre image avec l'image publique `latest` du service voisin. Ses bases de test utilisent des volumes temporaires supprimés à la fin du job.

Le test fonctionnel crée une commande par KrakenD, vérifie la création du paiement, traite ce paiement et vérifie que le paiement et la commande sont payés. Après déploiement, ce test crée une seule commande fictive sur la grappe. Les tests Locust se font séparément, dans l'environnement prévu pour la charge.

## 2. Configuration utilisée

| Paramètre | Valeur |
|---|---|
| Dépôt Store Manager | `https://github.com/ryokxii/log430-labo5-A26` |
| Dépôt Payment API | `https://github.com/ryokxii/log430-labo5-payment` |
| Workflow Store Manager | `CI CD Store Manager` |
| Workflow Payment API | `CI CD Payment API` |
| Image Store Manager | `ghcr.io/picodoux/log430-labo5-a26` |
| Image Payment API | `ghcr.io/picodoux/log430-labo5-payment` |
| Branche | `main` |
| Contexte Kubernetes | `etudiant_37@log430` |
| Namespace | `log430-espace-etudiant-10` |
| Serveur Kubernetes | `https://atreides.logti.etsmtl.ca:16443` |
| Labels des runners Windows | `self-hosted`, `Windows`, `X64`, `log430-ets` |

Les chemins ci-dessous correspondent au PC de déploiement utilisé dans le projet. Sur un autre ordinateur, adapter les chemins et le contexte Kubernetes à l'identité autorisée de son utilisateur.

## 3. Prérequis à configurer une seule fois

- Les deux services et leurs dépendances sont déjà déployés dans le namespace de l'équipe. Les deux images `latest` existent sur GHCR et sont publiques.
- `git` et `kubectl` sont accessibles dans PowerShell sur le PC de déploiement. Le kubeconfig contient les certificats d'accès et le contexte indiqué ci-dessus.
- Le secret **Actions** `GHCR_TOKEN` est enregistré dans chacun des deux dépôts, sous **Settings > Secrets and variables > Actions**. Sa valeur est un token classique du compte `picodoux` avec `write:packages`.
- Les deux runners Windows sont installés et enregistrés, chacun pour son dépôt et dans son propre dossier.
- Les fichiers du labo et les correctifs de déploiement sont commités sur GitHub, notamment l'appel PowerShell avec `RemoteSigned` et la readinessProbe de Store Manager.

Les tokens, les clés privées et les certificats Kubernetes restent hors du dépôt et du rapport. La publication utilise le secret GitHub; le déploiement réutilise le kubeconfig du compte Windows exécutant le runner.

Si un runner doit être installé à nouveau, le propriétaire du dépôt ouvre **Settings > Actions > Runners > New self-hosted runner**, choisit **Windows / x64** et suit les commandes GitHub dans le dossier prévu pour ce runner. Ajouter le label `log430-ets`, accepter le dossier de travail `_work` et répondre **N** à l'installation en service Windows. Le token temporaire d'enregistrement est propre à chaque dépôt et différent de `GHCR_TOKEN`.

## 4. Préparer une séance

1. Connecter le PC au VPN de l'ÉTS ou au réseau du campus.
2. Ouvrir PowerShell avec le compte Windows ayant configuré Kubernetes.
3. Vérifier les outils et l'accès :

```powershell
Get-Command git, kubectl

kubectl --context etudiant_37@log430 -n log430-espace-etudiant-10 auth whoami

kubectl --context etudiant_37@log430 -n log430-espace-etudiant-10 get deployments,pods,services,pvc
```

L'identité attendue est `etudiant_37`. Les composants attendus sont `mysql`, `redis`, `store-manager`, `mysql-payments`, `payments-api` et `api-gateway`. Si le serveur n'est pas joignable, rétablir l'accès au réseau de l'ÉTS avant de lancer le déploiement.

## 5. Démarrer les runners

### Terminal PowerShell 1 : Store Manager

```powershell
cd "C:\Users\aliha\actions-runners\store-manager"
.\run.cmd
```

### Terminal PowerShell 2 : Payment API

```powershell
cd "C:\Users\aliha\actions-runners\payments-api"
.\run.cmd
```

Chaque terminal doit afficher `Connected to GitHub`, puis `Listening for Jobs`. Dans **Settings > Actions > Runners** du dépôt correspondant, le runner doit être **Idle**, puis passer en activité lorsqu'il reçoit un job. Garder les terminaux ouverts, le PC allumé et le VPN connecté pendant les déploiements.

Un runner déjà en écoute peut être conservé tel quel. Utiliser un seul processus `run.cmd` par installation. Après la fin des jobs, `Ctrl+C` dans chaque terminal arrête le runner; la prochaine séance reprend avec les mêmes commandes.

Les deux workflows utilisent la même grappe et la même passerelle. **Lancer Store Manager, attendre la fin complète de son workflow, puis lancer Payment API.** Si les deux jobs sont déjà en attente, démarrer d'abord le runner Store Manager et attendre la fin de son déploiement avant de démarrer celui du paiement.

## 6. Lancer les workflows

### Option A : lancement manuel pour une démonstration

1. Ouvrir le dépôt Store Manager sur GitHub et cliquer sur **Actions**.
2. Sélectionner **CI CD Store Manager**.
3. Cliquer sur **Run workflow**, choisir la branche **main**, puis confirmer **Run workflow**.
4. Attendre que les deux jobs soient verts.
5. Dans le dépôt Payment API, refaire la même procédure avec **CI CD Payment API**, toujours sur **main**.

Cette méthode teste et déploie le code déjà présent sur GitHub. Les modifications locales doivent d'abord être commitées et poussées pour être prises en compte.

### Option B : lancement automatique après un push

Exemple pour publier cette documentation dans Store Manager, depuis un troisième terminal disponible, après avoir placé `CI_CD.md` à la racine du dépôt :

```powershell
cd "C:\Users\aliha\Documents\GitHub\log430-labo5-A26"
git status
git add CI_CD.md README.md
git commit -m "Documente le lancement du CI CD"
git push origin main
```

Le push déclenche automatiquement le workflow. Attendre la réussite des deux jobs, puis publier le même document dans le dépôt du paiement :

```powershell
cd "C:\Users\aliha\Documents\GitHub\log430-labo5-payment"
git status
git add CI_CD.md README.md
git commit -m "Documente le lancement du CI CD"
git push origin main
```

Pour d'autres changements, ajouter au commit les fichiers concernés avant le push. Si Git indique qu'il n'y a rien à commiter, utiliser le lancement manuel pour exécuter la version déjà publiée.

## 7. Vérifier la réussite du déploiement

Pour chaque dépôt, ouvrir la nouvelle exécution dans **Actions** et vérifier que les deux jobs sont verts. Dans les détails, relever le résumé pytest, les tags publiés sur GHCR, les rollouts et le résultat du test fonctionnel après déploiement.

Le résultat attendu du test ressemble à ceci :

```json
{"result":"PASS","order_id":123,"payment_id":456,"payment_is_paid":true,"order_is_paid":true}
```

Les identifiants ci-dessus sont des exemples. Utiliser les valeurs réellement produites par l'exécution. Le test utilise l'utilisateur 1, le produit 1 et une unité de stock; ces données doivent être présentes sur la grappe.

Vérifier ensuite l'état et les images depuis PowerShell :

```powershell
kubectl --context etudiant_37@log430 -n log430-espace-etudiant-10 get deployments,pods,services,pvc

kubectl --context etudiant_37@log430 -n log430-espace-etudiant-10 get deployment store-manager -o jsonpath='{.spec.template.spec.containers[0].image}'

kubectl --context etudiant_37@log430 -n log430-espace-etudiant-10 get deployment payments-api -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Pour chaque service, comparer le tag SHA affiché avec le commit de son exécution GitHub Actions. Les deux dépôts ont chacun leur commit et peuvent donc avoir des tags SHA différents.

Store Manager possède une readinessProbe sur `/health-check` et `minReadySeconds: 5`. Ces réglages attendent que Flask réponde et reste disponible avant la fin du rollout. Le script corrigé de Store Manager sélectionne un Pod Ready de l'image courante, en excluant les Pods en cours d'arrêt, pour exécuter le test.

La mise à jour conserve les PVC existants. Une modification des scripts SQL dans une ConfigMap ne réinitialise pas une base déjà persistante.

## 8. Preuves à conserver pour le rapport et la démonstration

La grille demande un pipeline automatisé incluant le déploiement, documenté avec du texte et des captures, utilisé activement et expliqué en démonstration.

Pour chacun des deux dépôts, conserver les preuves suivantes :

| Preuve | Explication à ajouter dans le rapport |
|---|---|
| Vue de l'exécution GitHub Actions avec les deux jobs verts et le commit | Indiquer le dépôt, le déclencheur et le commit concerné. |
| Résumé pytest et résultat du test fonctionnel en CI | Expliquer quels tests ont passé et que le parcours commande/paiement est vérifié. |
| Publication sur GHCR et tags de l'image | Expliquer la différence entre `latest` et le tag SHA utilisé pour le déploiement. |
| Rollouts et JSON `PASS` du test sur la grappe | Donner les identifiants réels et expliquer que le paiement et la commande sont bien payés. |
| Pods prêts et images déployées avec les tags SHA | Relier chaque image installée au commit de l'exécution réussie. |

Les preuves peuvent être regroupées dans quelques captures lisibles et légendées. Les exécutions et leurs résultats réels constituent les preuves de fonctionnement; ce document décrit la procédure.

Pendant la démonstration, montrer le déclenchement, expliquer le rôle des deux jobs, puis vérifier la version déployée et le résultat fonctionnel. Expliquer que le runner Windows utilise l'accès réseau et le kubeconfig du PC pour joindre la grappe du cours.

## 9. Résoudre les erreurs courantes

| Symptôme | Vérification ou correction |
|---|---|
| `Waiting for a runner to pick up this job` | Vérifier `run.cmd`, le bon dépôt et les quatre labels, dont `log430-ets`. |
| `running scripts is disabled` | Conserver la ligne `shell` complète du workflow, avec `-ExecutionPolicy RemoteSigned`, puis pousser la correction. Ce réglage s'applique au processus de l'étape. |
| Publication GHCR refusée | Vérifier le secret `GHCR_TOKEN` du dépôt, son expiration et la permission `write:packages` du compte `picodoux`. |
| Serveur Kubernetes inaccessible ou contexte absent | Vérifier le VPN, le contexte et le compte Windows exécutant le runner. |
| `ImagePullBackOff` | Vérifier que le tag SHA existe sur GHCR et que l'image est publique. |
| Connexion refusée vers Store Manager après un rollout | Vérifier que le manifeste contient la readinessProbe HTTP et que le script corrigé choisit un Pod actif. |
| HTTP 500 ou test fonctionnel en échec | Lire les journaux du job, de KrakenD et du Pod concerné. Vérifier l'erreur réelle avant de relancer. |

Après une correction du code ou du workflow, pousser un **nouveau commit**, puis suivre sa nouvelle exécution. Le bouton **Re-run jobs** d'une ancienne exécution réutilise son ancien commit. Il convient pour reprendre ce même commit après avoir rétabli l'environnement, par exemple le VPN ou le runner.